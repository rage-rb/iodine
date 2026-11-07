#include "iodine.h"

/* *****************************************************************************
Performance metrics
***************************************************************************** */

/**
 * Iodine::Perf.queued_connections
 *
 * Returns the total number of established connections currently parked in
 * the kernel's accept queue(s) (sk_ack_backlog) for all iodine listening
 * sockets. Returns 0 when there are no listeners and nil on non-Linux systems.
 */
static VALUE iodine_perf_queued_connections(VALUE self) {
  (void)self;
#if defined(__linux__)
  intptr_t backlog = fio_queued_connections();
  return INT2NUM((long)backlog);
#else
  return Qnil;
#endif
}

/**
 * Iodine::Perf.elu_enable_idle_time!
 *
 * Enables event loop utilization (ELU) tracking.
 * Disabled by default.
 *
 * Returns true (calling it more than once does nothing).
 */
static VALUE iodine_perf_elu_enable_idle_time(VALUE self) {
  (void)self;
  fio_elu_enable();
  return Qtrue;
}

/**
 * Iodine::Perf.elu_snapshot
 *
 * Reads both ELU counters at a single point in time, so that idle and
 * elapsed always belong to the same instant.
 *
 * Returns nil unless ELU tracking was enabled; otherwise
 * [idle_time_ns, elapsed_ns], both increasing Integer counts.
 */
static VALUE iodine_perf_elu_snapshot(VALUE self) {
  uint64_t idle_time, elapsed_time;

  (void)self;
  if (!fio_elu_is_enabled()) {
    return Qnil;
  }
  fio_elu_snapshot(&idle_time, &elapsed_time);
  return rb_ary_new_from_args(2, ULL2NUM(idle_time), ULL2NUM(elapsed_time));
}

void iodine_perf_initialize(void) {
  VALUE IodinePerfModule = rb_define_module_under(IodineModule, "Perf");
  rb_define_module_function(IodinePerfModule, "queued_connections",
                            iodine_perf_queued_connections, 0);
  /* The ELU (event loop utilization) group. */
  rb_define_module_function(IodinePerfModule, "elu_enable_idle_time!",
                            iodine_perf_elu_enable_idle_time, 0);
  rb_define_module_function(IodinePerfModule, "elu_snapshot",
                            iodine_perf_elu_snapshot, 0);
}
