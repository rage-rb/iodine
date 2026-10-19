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
 * Iodine::Perf.enable_idle_time!
 *
 * Enables event-loop utilization tracking.
 * Disabled by default.
 *
 * Returns true (calling it more than once does nothing).
 */
static VALUE iodine_perf_enable_idle_time(VALUE self) {
  (void)self;
  fio_elu_enable();
  return Qtrue;
}

/**
 * Iodine::Perf.idle_time_ns
 *
 * Cumulative nanoseconds genuinely spent waiting inside the event provider.
 *
 * Returns nil unless tracking was enabled; otherwise an increasing
 * Integer nanoseconds count.
 */
static VALUE iodine_perf_idle_time_ns(VALUE self) {
  (void)self;
  if (!fio_elu_is_enabled()) {
    return Qnil;
  }
  return ULL2NUM(fio_elu_idle_ns());
}

/**
 * Iodine::Perf.elapsed_ns
 *
 * Elapsed nanoseconds since tracking was enabled (same window as idle).
 * Returns nil unless tracking was enabled.
 */
static VALUE iodine_perf_elapsed_ns(VALUE self) {
  (void)self;
  if (!fio_elu_is_enabled()) {
    return Qnil;
  }
  return ULL2NUM(fio_elu_elapsed_ns());
}

void iodine_perf_initialize(void) {
  VALUE IodinePerfModule = rb_define_module_under(IodineModule, "Perf");
  rb_define_module_function(IodinePerfModule, "queued_connections",
                            iodine_perf_queued_connections, 0);
  rb_define_module_function(IodinePerfModule, "enable_idle_time!",
                            iodine_perf_enable_idle_time, 0);
  rb_define_module_function(IodinePerfModule, "idle_time_ns",
                            iodine_perf_idle_time_ns, 0);
  rb_define_module_function(IodinePerfModule, "elapsed_ns",
                            iodine_perf_elapsed_ns, 0);
}
