#include "iodine.h"
#include "iodine_store.h"
#include "ruby.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
// clang-format on

#include "fio.h"

#define IO_MAX_READ 8192

static ID call_id;
static uint8_t ATTACH_ON_READ_READY_CALLBACK;
static uint8_t ATTACH_ON_WRITE_READY_CALLBACK;
static VALUE e_timeout_args[1];
static VALUE e_badf_args[1];

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
    IodineCaller.call2(protocol->block, call_id, 1, e_badf_args);
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

  Check_Type(r_timeout, T_FIXNUM);
  size_t timeout = FIX2UINT(r_timeout);

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
  if (timeout) {
    fio_timeout_set(uuid, timeout);
  }

  fio_watch(uuid, (fio_protocol_s *)protocol);

  return LONG2NUM(uuid);
  (void)self;
}

static VALUE iodine_scheduler_write(VALUE self, VALUE r_fd, VALUE r_buffer, VALUE r_length, VALUE r_offset) {
  Check_Type(r_fd, T_FIXNUM);
  int fd = FIX2INT(r_fd);

  Check_Type(r_buffer, T_STRING);
  char *buffer = RSTRING_PTR(r_buffer);

  Check_Type(r_length, T_FIXNUM);
  int length = FIX2INT(r_length);

  Check_Type(r_offset, T_FIXNUM);
  int offset = FIX2INT(r_offset);

  void *cpy = fio_malloc(length);
  memcpy(cpy, buffer, length);
  fio_write2(fio_fd2uuid(fd), .data.buffer = cpy, .length = length, .offset = offset, .after.dealloc = fio_free);

  return r_length;

  (void)self;
}

static VALUE iodine_scheduler_read(VALUE self, VALUE r_fd, VALUE r_length, VALUE r_offset) {
  Check_Type(r_fd, T_FIXNUM);
  int fd = FIX2INT(r_fd);

  Check_Type(r_length, T_FIXNUM);
  int length = FIX2INT(r_length);

  if (length == 0) {
    length = IO_MAX_READ;
  }

  intptr_t uuid = fio_fd2uuid(fd);
  char buffer[length];

  ssize_t len = fio_read_unsafe(uuid, &buffer, length);
  if (len == -1) {
    return Qnil;
  }

  return rb_str_new(buffer, len);

  (void)self;
  (void)r_offset;
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
  e_badf_args[0] = INT2NUM(-EBADF);

  VALUE SchedulerModule = rb_define_module_under(IodineModule, "Scheduler");

  rb_define_module_function(SchedulerModule, "attach", iodine_scheduler_attach, 3);
  rb_define_module_function(SchedulerModule, "write", iodine_scheduler_write, 4);
  rb_define_module_function(SchedulerModule, "read", iodine_scheduler_read, 3);
  rb_define_module_function(SchedulerModule, "close", iodine_scheduler_close, 0);

  VALUE cIO = rb_const_get(rb_cObject, rb_intern2("IO", 2));
  VALUE io_readable = rb_const_get(cIO, rb_intern2("READABLE", 8));
  VALUE io_writable = rb_const_get(cIO, rb_intern2("WRITABLE", 8));

  ATTACH_ON_READ_READY_CALLBACK = NUM2SHORT(io_readable);
  ATTACH_ON_WRITE_READY_CALLBACK = NUM2SHORT(io_writable);
}
