/*
Test helpers for Iodine::WorkerPool.

Provides:
- busy(duration:): Blocking operation that releases the GVL.
  When called within a fiber scheduler context, this will trigger
  blocking_operation_wait and use the worker pool.

Based on io-event worker_pool_test.c by Samuel Williams.
*/

#include "iodine.h"

#ifdef HAVE_IODINE_WORKER_POOL

#include "iodine_worker_pool_test.h"

#include <ruby/thread.h>
#include <ruby/fiber/scheduler.h>
#include <unistd.h>
#include <sys/select.h>

static ID id_duration;

struct busy_operation_data {
  int read_fd;
  int write_fd;
  double duration;
};

/* The actual blocking operation that can be cancelled */
static void *busy_blocking_operation(void *data) {
  struct busy_operation_data *busy_data = (struct busy_operation_data *)data;

  /* Use select() to wait for the pipe to become readable */
  fd_set read_fds;
  struct timeval timeout;

  FD_ZERO(&read_fds);
  FD_SET(busy_data->read_fd, &read_fds);

  timeout.tv_sec = (long)busy_data->duration;
  timeout.tv_usec = (int)((busy_data->duration - timeout.tv_sec) * 1000000);

  /* This will block until:
     1. The pipe becomes readable (cancellation)
     2. The timeout expires
     3. An error occurs */
  int result = select(busy_data->read_fd + 1, &read_fds, NULL, NULL, &timeout);

  if (result > 0 && FD_ISSET(busy_data->read_fd, &read_fds)) {
    /* Pipe became readable - we were cancelled */
    char buffer;
    read(busy_data->read_fd, &buffer, 1);
  }

  return NULL;
}

/* Unblock function that writes to the pipe to cancel the operation */
static void busy_unblock_function(void *data) {
  struct busy_operation_data *busy_data = (struct busy_operation_data *)data;
  char wake_byte = 1;
  write(busy_data->write_fd, &wake_byte, 1);
}

/* Cleanup function for rb_ensure */
static VALUE busy_operation_cleanup(VALUE data_value) {
  struct busy_operation_data *busy_data =
      (struct busy_operation_data *)data_value;
  close(busy_data->read_fd);
  close(busy_data->write_fd);
  return Qnil;
}

/* The main operation execution */
static VALUE busy_operation_execute(VALUE data_value) {
  struct busy_operation_data *busy_data =
      (struct busy_operation_data *)data_value;

  rb_nogvl(busy_blocking_operation, busy_data, busy_unblock_function, busy_data,
           RB_NOGVL_UBF_ASYNC_SAFE | RB_NOGVL_OFFLOAD_SAFE);

  return Qnil;
}

/**
 * Iodine::WorkerPool.busy(duration: 1.0) -> nil
 *
 * Creates a blocking operation for testing that releases the GVL.
 * When called within a fiber scheduler context with a worker pool,
 * this will trigger blocking_operation_wait.
 *
 * @param duration [Float] How long to block (default: 1.0 second)
 * @return [nil]
 */
static VALUE worker_pool_test_busy(int argc, VALUE *argv, VALUE self) {
  double duration = 1.0;

  VALUE kwargs = Qnil;
  VALUE rb_duration = Qundef;

  rb_scan_args(argc, argv, "0:", &kwargs);

  if (!NIL_P(kwargs)) {
    VALUE kwvals[1];
    ID kwkeys[1] = {id_duration};
    rb_get_kwargs(kwargs, kwkeys, 0, 1, kwvals);
    rb_duration = kwvals[0];
  }

  if (rb_duration != Qundef && !NIL_P(rb_duration)) {
    duration = NUM2DBL(rb_duration);
  }

  /* Create pipe for cancellation */
  int pipe_fds[2];
  if (pipe(pipe_fds) != 0) {
    rb_sys_fail("pipe creation failed");
  }

  struct busy_operation_data busy_data = {
      .read_fd = pipe_fds[0], .write_fd = pipe_fds[1], .duration = duration};

  return rb_ensure(busy_operation_execute, (VALUE)&busy_data,
                   busy_operation_cleanup, (VALUE)&busy_data);
  (void)self;
}

/* Initialize the test functions */
void iodine_worker_pool_test_init(VALUE WorkerPoolKlass) {
  id_duration = rb_intern("duration");

  rb_define_singleton_method(WorkerPoolKlass, "__busy", worker_pool_test_busy,
                             -1);
}

#else /* !HAVE_IODINE_WORKER_POOL */

void iodine_worker_pool_test_init(VALUE WorkerPoolKlass) {
  /* WorkerPool not available */
  (void)WorkerPoolKlass;
}

#endif /* HAVE_IODINE_WORKER_POOL */
