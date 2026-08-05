#include "iodine_rack_stream.h"

#include "iodine.h"

typedef enum {
  IODINE_STREAM_IDLE = 0,     /* created, nothing written yet */
  IODINE_STREAM_HEADERS_SENT, /* first write flushed the response headers */
  IODINE_STREAM_STREAMING,    /* chunks flowing */
  IODINE_STREAM_BLOCKED,      /* caller must wait for readiness and retry */
  IODINE_STREAM_CLOSING,      /* close requested, finishing safely */
  IODINE_STREAM_CLOSED,       /* terminal: completed */
  IODINE_STREAM_ERROR,        /* terminal: write failure / disconnect */
} iodine_stream_state_e;

typedef enum {
  IODINE_STREAM_TRANSPORT_ACTIVE = 0,
  IODINE_STREAM_TRANSPORT_PAUSING,
  IODINE_STREAM_TRANSPORT_PAUSED,
  IODINE_STREAM_TRANSPORT_RESUMING,
  IODINE_STREAM_TRANSPORT_TERMINAL,
} iodine_stream_transport_state_e;

typedef struct {
  http_s *h; /* valid only while transport_state is ACTIVE */
  http_pause_handle_s *pause_handle;
  intptr_t uuid;               /* socket uuid, for fio_pending / fio_is_valid */
  iodine_stream_state_e state;
  iodine_stream_transport_state_e transport_state;
  fio_lock_i lock;
  size_t high_watermark;       /* pause threshold */
  size_t low_watermark;        /* resume threshold */
  int blocked;                 /* backpressure flag */
  int close_requested;
  int freed;                   /* terminal guard: teardown runs exactly once */
} stream_ctx_t;

typedef struct {
  stream_ctx_t *ctx;
  const char *data;
  size_t length;
  VALUE result;
} stream_write_args_s;

/* Watermarks are queued-packet counts ; each write is sliced
 * into CHUNK_SIZE packets, so 1 packet ~= 16KB. */
#define IODINE_STREAM_CHUNK_SIZE (16 * 1024)
#define IODINE_STREAM_LOW_WATERMARK 4
#define IODINE_STREAM_HIGH_WATERMARK 16
#define IODINE_STREAM_HARD_MAX 64

/* *****************************************************************************
Core data / helpers
***************************************************************************** */

static VALUE rRackStream;

static ID ctx_var_id;   /* ivar holding the stream_ctx_t pointer */
static ID iodine_new_func_id;

/* write() return values (cached symbols) */
static VALUE SYM_ok;
static VALUE SYM_closed;
static VALUE SYM_disconnected;
static VALUE SYM_would_block;
static VALUE SYM_error;

static void stream_on_paused(http_pause_handle_s *pause_handle);
static void stream_finish_resumed(http_s *h);
static void stream_finish_fallback(void *udata);
static VALUE rack_stream_close(VALUE self);

#define set_ctx(object, ctx)                                   \
  rb_ivar_set((object), ctx_var_id, ULL2NUM((uintptr_t)(ctx)))

inline static stream_ctx_t *get_ctx(VALUE obj) {
  VALUE i = rb_ivar_get(obj, ctx_var_id);
  return (stream_ctx_t *)NUM2ULL(i);
}

/* Frees native state after the final handle or pause token is consumed. */
static void stream_ctx_free(stream_ctx_t *ctx) {
  if (!ctx)
    return;

  fio_lock(&ctx->lock);
  if (ctx->freed) {
    fio_unlock(&ctx->lock);
    return;
  }
  ctx->freed = 1;
  ctx->state = IODINE_STREAM_CLOSED;
  ctx->transport_state = IODINE_STREAM_TRANSPORT_TERMINAL;
  fio_unlock(&ctx->lock);
  free(ctx);
}

static void stream_finish_resumed(http_s *h) {
  stream_ctx_t *ctx = h->udata;
  http_finish(h);
  stream_ctx_free(ctx);
}

static void stream_finish_fallback(void *udata) {
  stream_ctx_free(udata);
}

static void stream_resume_finish(http_pause_handle_s *pause_handle) {
  http_resume(pause_handle, stream_finish_resumed, stream_finish_fallback);
}

static void stream_on_paused(http_pause_handle_s *pause_handle) {
  stream_ctx_t *ctx = http_paused_udata_get(pause_handle);
  int finish = 0;

  fio_lock(&ctx->lock);
  if (ctx->close_requested) {
    ctx->transport_state = IODINE_STREAM_TRANSPORT_RESUMING;
    finish = 1;
  } else {
    ctx->pause_handle = pause_handle;
    ctx->transport_state = IODINE_STREAM_TRANSPORT_PAUSED;
  }
  fio_unlock(&ctx->lock);

  if (finish)
    stream_resume_finish(pause_handle);
}

/* Sends one complete application chunk through a currently valid HTTP handle. */
static VALUE stream_write_with_handle(stream_ctx_t *ctx, http_s *h,
                                      const char *data, size_t length) {
  const char *p = data;
  size_t remaining = length;

  do {
    size_t n =
        remaining < IODINE_STREAM_CHUNK_SIZE ? remaining : IODINE_STREAM_CHUNK_SIZE;
    if (http_stream(h, (void *)p, n) < 0) {
      ctx->state = IODINE_STREAM_ERROR;
      return SYM_error;
    }
    p += n;
    remaining -= n;
  } while (remaining);

  if (ctx->state < IODINE_STREAM_CLOSING) {
    ctx->state = IODINE_STREAM_STREAMING;
    ctx->blocked = 0;
  }
  return SYM_ok;
}

static void stream_write_resumed(http_s *h, void *udata) {
  stream_write_args_s *args = udata;
  stream_ctx_t *ctx = args->ctx;
  int close_requested = 0;

  args->result = stream_write_with_handle(ctx, h, args->data, args->length);

  fio_lock(&ctx->lock);
  close_requested = ctx->close_requested;
  if (args->result == SYM_ok && !close_requested)
    ctx->transport_state = IODINE_STREAM_TRANSPORT_PAUSING;
  else
    ctx->transport_state = IODINE_STREAM_TRANSPORT_TERMINAL;
  fio_unlock(&ctx->lock);

  if (args->result == SYM_ok && !close_requested) {
    h->udata = ctx;
    http_pause(h, stream_on_paused);
  } else {
    if (http_uuid(h) != -1)
      http_finish(h);
    if (close_requested)
      stream_ctx_free(ctx);
  }
}

/* *****************************************************************************
Ruby API
***************************************************************************** */

/* Writes one chunk, returns a status symbol; never blocks. Backpressure is gated
 * once up front so the send stays atomic (a :would_block retry can't duplicate a
 * partially-sent chunk). */
static VALUE rack_stream_write(VALUE self, VALUE data) {
  stream_ctx_t *ctx = get_ctx(self);

  /* 1. terminal state -> closed (flag check) */
  if (!ctx || ctx->state >= IODINE_STREAM_CLOSED)
    return SYM_closed;

  /* 2. socket disconnected -> disconnected */
  if (!fio_is_valid(ctx->uuid)) {
    rack_stream_close(self);
    return SYM_disconnected;
  }

  /* 3. type check -> TypeError if not a String */
  Check_Type(data, T_STRING);

  /* 4. count packets this write adds; a big write can enqueue many at once */
  size_t pending = fio_pending(ctx->uuid);
  size_t packets_needed =
      (RSTRING_LEN(data) + IODINE_STREAM_CHUNK_SIZE - 1) / IODINE_STREAM_CHUNK_SIZE;

  /* 5. HARD_MAX -> unrecoverable (queue maxed, or write too big to ever fit) */
  if (pending >= IODINE_STREAM_HARD_MAX ||
      packets_needed >= IODINE_STREAM_HARD_MAX) {
    ctx->state = IODINE_STREAM_ERROR;
    return SYM_error;
  }

  /* 6. backpressure -> caller-owned wait/retry (would overflow HARD or past HIGH)
   * TODO(phase-3): publish readiness from http1_on_ready at LOW. */
  if (pending + packets_needed >= IODINE_STREAM_HARD_MAX ||
      pending >= ctx->high_watermark) {
    ctx->blocked = 1;
    ctx->state = IODINE_STREAM_BLOCKED;
    return SYM_would_block;
  }

  /* 7. send through the active handle, or try to consume the paused handle.
   * A busy/missing pause token accepts no bytes and is safe to retry. */
  http_s *h = NULL;
  http_pause_handle_s *pause_handle = NULL;

  fio_lock(&ctx->lock);
  if (ctx->transport_state == IODINE_STREAM_TRANSPORT_ACTIVE) {
    h = ctx->h;
  } else if (ctx->transport_state == IODINE_STREAM_TRANSPORT_PAUSED) {
    pause_handle = ctx->pause_handle;
    ctx->pause_handle = NULL;
    ctx->transport_state = IODINE_STREAM_TRANSPORT_RESUMING;
  }
  fio_unlock(&ctx->lock);

  if (h)
    return stream_write_with_handle(ctx, h, RSTRING_PTR(data), RSTRING_LEN(data));

  if (!pause_handle) {
    ctx->blocked = 1;
    ctx->state = IODINE_STREAM_BLOCKED;
    return SYM_would_block;
  }

  stream_write_args_s args = {
      .ctx = ctx,
      .data = RSTRING_PTR(data),
      .length = RSTRING_LEN(data),
      .result = SYM_error,
  };
  int resume_result =
      http_resume_try(pause_handle, stream_write_resumed, &args, NULL);

  if (resume_result > 0) {
    fio_lock(&ctx->lock);
    ctx->pause_handle = pause_handle;
    ctx->transport_state = IODINE_STREAM_TRANSPORT_PAUSED;
    fio_unlock(&ctx->lock);
    ctx->blocked = 1;
    ctx->state = IODINE_STREAM_BLOCKED;
    return SYM_would_block;
  }

  if (resume_result < 0) {
    fio_lock(&ctx->lock);
    ctx->transport_state = IODINE_STREAM_TRANSPORT_TERMINAL;
    fio_unlock(&ctx->lock);
    ctx->state = IODINE_STREAM_ERROR;
    set_ctx(self, NULL);
    stream_ctx_free(ctx);
    return SYM_disconnected;
  }

  if (args.result != SYM_ok) {
    set_ctx(self, NULL);
    stream_ctx_free(ctx);
  }
  return args.result;
}

/* Closes the stream. Idempotent in every state. Sends the terminating
 * zero-length chunk via http_finish exactly once when the connection is still
 * alive, then frees the context. */
static VALUE rack_stream_close(VALUE self) {
  stream_ctx_t *ctx = get_ctx(self);
  if (!ctx || ctx->freed)
    return Qnil; /* already closed -> no-op */

  http_s *h = NULL;
  http_pause_handle_s *pause_handle = NULL;
  int free_now = 0;

  /* Detach immediately so repeated Ruby close calls are idempotent. Native
   * state remains alive until any outstanding pause token is consumed. */
  set_ctx(self, NULL);

  fio_lock(&ctx->lock);
  ctx->close_requested = 1;
  ctx->state = IODINE_STREAM_CLOSING;
  switch (ctx->transport_state) {
  case IODINE_STREAM_TRANSPORT_ACTIVE:
    h = ctx->h;
    ctx->h = NULL;
    ctx->transport_state = IODINE_STREAM_TRANSPORT_TERMINAL;
    free_now = 1;
    break;
  case IODINE_STREAM_TRANSPORT_PAUSED:
    pause_handle = ctx->pause_handle;
    ctx->pause_handle = NULL;
    ctx->transport_state = IODINE_STREAM_TRANSPORT_RESUMING;
    break;
  case IODINE_STREAM_TRANSPORT_TERMINAL:
    free_now = 1;
    break;
  case IODINE_STREAM_TRANSPORT_PAUSING:
  case IODINE_STREAM_TRANSPORT_RESUMING:
    break;
  }
  fio_unlock(&ctx->lock);

  if (h) {
    if (fio_is_valid(ctx->uuid) && http_uuid(h) != -1)
      http_finish(h);
    stream_ctx_free(ctx);
  } else if (pause_handle) {
    stream_resume_finish(pause_handle);
  } else if (free_now) {
    stream_ctx_free(ctx);
  }
  return Qnil;
}

/* True once the stream is terminal (or never started). */
static VALUE rack_stream_is_closed(VALUE self) {
  stream_ctx_t *ctx = get_ctx(self);
  if (!ctx || ctx->state >= IODINE_STREAM_CLOSED)
    return Qtrue;
  return Qfalse;
}

/* *****************************************************************************
C land API
***************************************************************************** */

static VALUE new_rack_stream(http_s *h) {
  stream_ctx_t *ctx = malloc(sizeof(*ctx));
  if (!ctx)
    return Qnil;
  *ctx = (stream_ctx_t){
      .h = h,
      .pause_handle = NULL,
      .uuid = http_uuid(h), /* stable connection id; cached for the write path */
      .state = IODINE_STREAM_IDLE,
      .transport_state = IODINE_STREAM_TRANSPORT_ACTIVE,
      .lock = FIO_LOCK_INIT,
      .high_watermark = IODINE_STREAM_HIGH_WATERMARK,
      .low_watermark = IODINE_STREAM_LOW_WATERMARK,
      .blocked = 0,
      .close_requested = 0,
      .freed = 0,
  };

  VALUE stream = rb_funcall2(rRackStream, iodine_new_func_id, 0, NULL);
  set_ctx(stream, ctx);
  return stream;
}

static void pause_rack_stream(VALUE stream) {
  stream_ctx_t *ctx = get_ctx(stream);
  http_s *h = NULL;
  int terminal = 0;

  if (!ctx)
    return;

  fio_lock(&ctx->lock);
  if (!ctx->close_requested &&
      ctx->transport_state == IODINE_STREAM_TRANSPORT_ACTIVE) {
    h = ctx->h;
    ctx->h = NULL;
    if (!h || ctx->state >= IODINE_STREAM_CLOSED || http_uuid(h) == -1) {
      ctx->transport_state = IODINE_STREAM_TRANSPORT_TERMINAL;
      terminal = 1;
    } else {
      ctx->transport_state = IODINE_STREAM_TRANSPORT_PAUSING;
    }
  }
  fio_unlock(&ctx->lock);

  if (!h)
    return;

  if (terminal) {
    set_ctx(stream, NULL);
    if (fio_is_valid(ctx->uuid) && http_uuid(h) != -1)
      http_finish(h);
    stream_ctx_free(ctx);
    return;
  }

  h->udata = ctx;
  http_pause(h, stream_on_paused);
}

/* *****************************************************************************
Initialization
***************************************************************************** */

static void init_rack_stream(void) {
  rRackStream = rb_define_class_under(IodineBaseModule, "RackStream", rb_cObject);

  ctx_var_id = rb_intern("stream_ctx");
  iodine_new_func_id = rb_intern("new");

  SYM_ok = ID2SYM(rb_intern("ok"));
  SYM_closed = ID2SYM(rb_intern("closed"));
  SYM_disconnected = ID2SYM(rb_intern("disconnected"));
  SYM_would_block = ID2SYM(rb_intern("would_block"));
  SYM_error = ID2SYM(rb_intern("error"));

  rb_define_method(rRackStream, "write", rack_stream_write, 1);
  rb_define_method(rRackStream, "close", rack_stream_close, 0);
  rb_define_method(rRackStream, "closed?", rack_stream_is_closed, 0);
}

struct IodineRackStream IodineRackStream = {
    .create = new_rack_stream,
    .pause = pause_rack_stream,
    .init = init_rack_stream,
};
