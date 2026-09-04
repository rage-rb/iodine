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

void iodine_perf_initialize(void) {
  VALUE IodinePerfModule = rb_define_module_under(IodineModule, "Perf");
  rb_define_module_function(IodinePerfModule, "queued_connections",
                            iodine_perf_queued_connections, 0);
}
