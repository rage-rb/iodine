#include "iodine.h"
#include "iodine_store.h"
#include "ruby.h"
#include "ruby/fiber/scheduler.h"
#include "ruby/io/buffer.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
// clang-format on

#include "fio.h"

#define IO_MAX_READ 65536

static ID call_id;
static uint8_t ATTACH_ON_READ_READY_CALLBACK;
static uint8_t ATTACH_ON_WRITE_READY_CALLBACK;
static VALUE e_timeout_args[1];
static VALUE e_closed_args[1];
static VALUE e_not_ready_args[1];

/* *****************************************************************************
Fiber Scheduler API
***************************************************************************** */

static void noop(intptr_t uuid, fio_protocol_s *protocol) {
  (void)uuid;
  (void)protocol;
}

typedef struct {
  fio_protocol_s p;
  VALUE block;
  uint8_t fulfilled;
} scheduler_protocol_s;


static void iodine_scheduler_task_close(intptr_t uuid, fio_protocol_s *fio_protocol) {
  scheduler_protocol_s *protocol = (scheduler_protocol_s *)fio_protocol;

  if (!protocol->fulfilled) {
    IodineCaller.call2(protocol->block, call_id, 1, e_closed_args);
  }

  IodineStore.remove(protocol->block);
  fio_free(protocol);

  (void)uuid;
}

static void iodine_scheduler_task_perform(intptr_t uuid, fio_protocol_s *fio_protocol) {
  scheduler_protocol_s *protocol = (scheduler_protocol_s *)fio_protocol;

  if (!protocol->fulfilled) {
    IodineCaller.call(protocol->block, call_id);
    protocol->fulfilled = 1;
  }

  (void)uuid;
}

static void iodine_scheduler_task_not_ready(void *uuid, void *fio_protocol) {
  scheduler_protocol_s *protocol = (scheduler_protocol_s *)fio_protocol;

  if (!protocol->fulfilled) {
    IodineCaller.call2(protocol->block, call_id, 1, e_not_ready_args);
    protocol->fulfilled = 1;
  }

  (void)uuid;
}

static void iodine_scheduler_task_deferred_not_ready(intptr_t uuid, fio_protocol_s *fio_protocol) {
  // if there's a read event, `fio_defer` will give it time to fulfill the protocol first;
  // otherwise, the fiber will be resumed with `false` indicating the IO is not ready
  fio_defer(iodine_scheduler_task_not_ready, (void *)uuid, (void *)fio_protocol);

  (void)uuid;
}

static void iodine_scheduler_task_timeout(intptr_t uuid, fio_protocol_s *fio_protocol) {
  scheduler_protocol_s *protocol = (scheduler_protocol_s *)fio_protocol;

  if (!protocol->fulfilled) {
    IodineCaller.call2(protocol->block, call_id, 1, e_timeout_args);
    protocol->fulfilled = 1;
  }
}

static VALUE iodine_scheduler_attach(VALUE self, VALUE r_fd, VALUE r_waittype, VALUE r_timeout) {
  Check_Type(r_fd, T_FIXNUM);
  int fd = FIX2INT(r_fd);

  Check_Type(r_waittype, T_FIXNUM);
  size_t waittype = FIX2UINT(r_waittype);

  size_t timeout;
  if (r_timeout != Qnil) {
    Check_Type(r_timeout, T_FIXNUM);
    timeout = FIX2UINT(r_timeout);
  }

  fio_set_non_block(fd);

  rb_need_block();
  VALUE block = IodineStore.add(rb_block_proc());

  scheduler_protocol_s *protocol = fio_malloc(sizeof(*protocol));
  FIO_ASSERT_ALLOC(protocol);

  if ((waittype & ATTACH_ON_READ_READY_CALLBACK) && (waittype & ATTACH_ON_WRITE_READY_CALLBACK)) {
    *protocol = (scheduler_protocol_s){
        .p.on_data = iodine_scheduler_task_perform,
        .p.on_ready = iodine_scheduler_task_perform,
        .p.on_close = iodine_scheduler_task_close,
        .p.ping = iodine_scheduler_task_timeout,
        .block = block,
    };
  } else if (waittype & ATTACH_ON_READ_READY_CALLBACK) {
    *protocol = (scheduler_protocol_s){
        .p.on_data = iodine_scheduler_task_perform,
        .p.on_ready = noop,
        .p.on_close = iodine_scheduler_task_close,
        .p.ping = iodine_scheduler_task_timeout,
        .block = block,
    };
  } else if (waittype & ATTACH_ON_WRITE_READY_CALLBACK) {
    *protocol = (scheduler_protocol_s){
        .p.on_data = noop,
        .p.on_ready = iodine_scheduler_task_perform,
        .p.on_close = iodine_scheduler_task_close,
        .p.ping = iodine_scheduler_task_timeout,
        .block = block,
    };
  }

  intptr_t uuid = fio_fd2uuid(fd);

  if (r_timeout == Qnil) {
    fio_timeout_set(uuid, 0);
  } else if (timeout) {
    fio_timeout_set(uuid, timeout);
  } else {
    // timeout was explicitly set to 0 - return right away
    protocol->p.on_ready = iodine_scheduler_task_deferred_not_ready;
  }

  fio_watch(uuid, (fio_protocol_s *)protocol);

  return LONG2NUM(uuid);
  (void)self;
}

static VALUE iodine_scheduler_write_async(VALUE self, VALUE r_fd, VALUE r_buffer, VALUE r_length, VALUE r_offset) {
  Check_Type(r_fd, T_FIXNUM);
  int fd = FIX2INT(r_fd);

  const void *buffer;
  size_t buffer_length;
  rb_io_buffer_get_bytes_for_reading(r_buffer, &buffer, &buffer_length);

  Check_Type(r_length, T_FIXNUM);
  size_t length = NUM2SIZET(r_length);

  Check_Type(r_offset, T_FIXNUM);
  size_t offset = NUM2SIZET(r_offset);

  if (offset > buffer_length || length > buffer_length - offset) {
    return rb_fiber_scheduler_io_result(-1, EINVAL);
  }
  if (!length) {
    return r_length;
  }

  void *cpy = fio_malloc(length);
  memcpy(cpy, (const char *)buffer + offset, length);
  fio_write2(fio_fd2uuid(fd), .data.buffer = cpy, .length = length, .after.dealloc = fio_free);

  return r_length;

  (void)self;
}

static VALUE iodine_scheduler_write(VALUE self, VALUE r_fd, VALUE r_buffer, VALUE r_length, VALUE r_offset) {
  Check_Type(r_fd, T_FIXNUM);
  int fd = FIX2INT(r_fd);

  const void *buffer;
  size_t buffer_length;
  rb_io_buffer_get_bytes_for_reading(r_buffer, &buffer, &buffer_length);

  Check_Type(r_length, T_FIXNUM);
  size_t length = NUM2SIZET(r_length);

  Check_Type(r_offset, T_FIXNUM);
  size_t offset = NUM2SIZET(r_offset);

  if (offset > buffer_length || length > buffer_length - offset) {
    return rb_fiber_scheduler_io_result(-1, EINVAL);
  }
  if (!length) {
    return rb_fiber_scheduler_io_result(0, 0);
  }

  ssize_t result = fio_write_once(fio_fd2uuid(fd), (const char *)buffer + offset, length);
  int error = result < 0 ? errno : 0;
  return rb_fiber_scheduler_io_result(result, error);

  (void)self;
}

static VALUE iodine_scheduler_read(VALUE self, VALUE r_fd, VALUE r_buffer, VALUE r_length, VALUE r_offset) {
  Check_Type(r_fd, T_FIXNUM);
  int fd = FIX2INT(r_fd);

  void *buffer;
  size_t buffer_length;
  rb_io_buffer_get_bytes_for_writing(r_buffer, &buffer, &buffer_length);

  Check_Type(r_length, T_FIXNUM);
  size_t length = NUM2SIZET(r_length);

  Check_Type(r_offset, T_FIXNUM);
  size_t offset = NUM2SIZET(r_offset);

  if (offset > buffer_length || length > buffer_length - offset) {
    return rb_fiber_scheduler_io_result(-1, EINVAL);
  }

  #if RUBY_FIBER_SCHEDULER_VERSION >= 4
    if (length > IO_MAX_READ) {
      length = IO_MAX_READ;
    }
  #else
    if (length == 0) {
      length = buffer_length - offset;
      if (length > IO_MAX_READ) {
        length = IO_MAX_READ;
      }
    }
  #endif

  if (!length) {
    return rb_fiber_scheduler_io_result(0, 0);
  }

  ssize_t result = fio_read_once(fio_fd2uuid(fd), (char *)buffer + offset, length);
  int error = result < 0 ? errno : 0;
  return rb_fiber_scheduler_io_result(result, error);

  (void)self;
}

static VALUE iodine_scheduler_close(VALUE self) {
  fio_defer_perform();
  while (fio_flush_all()) {}

  return Qtrue;
  (void)self;
}

/* *****************************************************************************
Scheduler initialization
***************************************************************************** */

void iodine_scheduler_initialize(void) {
  call_id = rb_intern2("call", 4);
  e_timeout_args[0] = INT2NUM(-ETIMEDOUT);
  e_closed_args[0] = INT2NUM(-EIO);
  e_not_ready_args[0] = Qfalse;

  VALUE SchedulerModule = rb_define_module_under(IodineModule, "Scheduler");

  rb_define_module_function(SchedulerModule, "attach", iodine_scheduler_attach, 3);
  rb_define_module_function(SchedulerModule, "write_async", iodine_scheduler_write_async, 4);
  rb_define_module_function(SchedulerModule, "write", iodine_scheduler_write, 4);
  rb_define_module_function(SchedulerModule, "read", iodine_scheduler_read, 4);
  rb_define_module_function(SchedulerModule, "close", iodine_scheduler_close, 0);

  VALUE cIO = rb_const_get(rb_cObject, rb_intern2("IO", 2));
  VALUE io_readable = rb_const_get(cIO, rb_intern2("READABLE", 8));
  VALUE io_writable = rb_const_get(cIO, rb_intern2("WRITABLE", 8));

  ATTACH_ON_READ_READY_CALLBACK = NUM2SHORT(io_readable);
  ATTACH_ON_WRITE_READY_CALLBACK = NUM2SHORT(io_writable);
}
