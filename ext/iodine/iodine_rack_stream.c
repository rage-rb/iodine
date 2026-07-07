#include "iodine_rack_stream.h"

#include "iodine.h"

typedef enum {
  IODINE_STREAM_IDLE = 0,     /* created, nothing written yet */
  IODINE_STREAM_HEADERS_SENT, /* first write flushed the response headers */
  IODINE_STREAM_STREAMING,    /* chunks flowing */
  IODINE_STREAM_BLOCKED,      /* paused on backpressure, fiber yielded */
  IODINE_STREAM_CLOSING,      /* close requested, finishing safely */
  IODINE_STREAM_CLOSED,       /* terminal: completed */
  IODINE_STREAM_ERROR,        /* terminal: write failure / disconnect */
} iodine_stream_state_e;

typedef struct {
  /* TODO(phase-3): don't persist across http_pause/http_resume (invalidates h). */
  http_s *h;
  intptr_t uuid;               /* socket uuid, for fio_pending / fio_is_valid */
  iodine_stream_state_e state;
  VALUE fiber;                 /* producer fiber; also held as an ivar so the GC marks it */
  size_t high_watermark;       /* pause threshold */
  size_t low_watermark;        /* resume threshold */
  int blocked;                 /* backpressure flag */
  int freed;                   /* terminal guard: teardown runs exactly once */
} stream_ctx_t;

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
static ID fiber_var_id; /* ivar holding the producer fiber */
static ID iodine_new_func_id;

/* write() return values (cached symbols) */
static VALUE SYM_ok;
static VALUE SYM_closed;
static VALUE SYM_disconnected;
static VALUE SYM_would_block;
static VALUE SYM_error;

#define set_ctx(object, ctx)                                   \
  rb_ivar_set((object), ctx_var_id, ULL2NUM((uintptr_t)(ctx)))

inline static stream_ctx_t *get_ctx(VALUE obj) {
  VALUE i = rb_ivar_get(obj, ctx_var_id);
  return (stream_ctx_t *)NUM2ULL(i);
}

/* Frees the context exactly once and detaches it from the Ruby object. */
static void stream_teardown(VALUE stream) {
  stream_ctx_t *ctx = get_ctx(stream);
  if (!ctx || ctx->freed)
    return;
  ctx->freed = 1;
  ctx->state = IODINE_STREAM_CLOSED;
  set_ctx(stream, NULL);
  rb_ivar_set(stream, fiber_var_id, Qnil);
  free(ctx);
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
    ctx->state = IODINE_STREAM_ERROR;
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

  /* 6. backpressure -> yield/retry (write would overflow HARD, or past HIGH)
   * TODO: register http_pause here and resume from http1_on_ready at LOW. */
  if (pending + packets_needed >= IODINE_STREAM_HARD_MAX ||
      pending >= ctx->high_watermark) {
    ctx->blocked = 1;
    ctx->state = IODINE_STREAM_BLOCKED;
    return SYM_would_block;
  }
 
  /* 7. send in <= CHUNK_SIZE slices; empty chunk runs once to flush headers. */
  const char *p = RSTRING_PTR(data);
  size_t remaining = RSTRING_LEN(data);
  do {
    size_t n =
        remaining < IODINE_STREAM_CHUNK_SIZE ? remaining : IODINE_STREAM_CHUNK_SIZE;
    if (http_stream(ctx->h, (void *)p, n) < 0) {
      ctx->state = IODINE_STREAM_ERROR;
      return SYM_error;
    }
    p += n;
    remaining -= n;
  } while (remaining);

  if (ctx->state < IODINE_STREAM_STREAMING)
    ctx->state = IODINE_STREAM_STREAMING; /* first write flushed the headers */
  return SYM_ok;
}

/* Closes the stream. Idempotent in every state. Sends the terminating
 * zero-length chunk via http_finish exactly once when the connection is still
 * alive, then frees the context. */
static VALUE rack_stream_close(VALUE self) {
  stream_ctx_t *ctx = get_ctx(self);
  if (!ctx || ctx->freed)
    return Qnil; /* already closed -> no-op */

  if (ctx->state < IODINE_STREAM_CLOSING && fio_is_valid(ctx->uuid)) {
    ctx->state = IODINE_STREAM_CLOSING;
    http_finish(ctx->h); /* invalidates the http_s handle */
  }
  stream_teardown(self);
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

static VALUE new_rack_stream(http_s *h, VALUE fiber) {
  stream_ctx_t *ctx = malloc(sizeof(*ctx));
  if (!ctx)
    return Qnil;
  *ctx = (stream_ctx_t){
      .h = h,
      .uuid = http_uuid(h), /* stable connection id; cached for the write path */
      .state = IODINE_STREAM_IDLE,
      .fiber = fiber,
      .high_watermark = IODINE_STREAM_HIGH_WATERMARK,
      .low_watermark = IODINE_STREAM_LOW_WATERMARK,
      .blocked = 0,
      .freed = 0,
  };

  VALUE stream = rb_funcall2(rRackStream, iodine_new_func_id, 0, NULL);
  set_ctx(stream, ctx);
  /* hold the fiber as an ivar so Ruby's GC keeps it alive while blocked. */
  rb_ivar_set(stream, fiber_var_id, fiber);
  return stream;
}

static void close_rack_stream(VALUE stream) { stream_teardown(stream); }

/* *****************************************************************************
Initialization
***************************************************************************** */

static void init_rack_stream(void) {
  rRackStream = rb_define_class_under(IodineBaseModule, "RackStream", rb_cObject);

  ctx_var_id = rb_intern("stream_ctx");
  fiber_var_id = rb_intern("stream_fiber");
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
    .close = close_rack_stream,
    .init = init_rack_stream,
};
