#include "iodine.h"

#include <ruby/version.h>

#define FIO_INCLUDE_LINKED_LIST
#include "fio.h"
/* *****************************************************************************
OS specific patches
***************************************************************************** */

#ifdef __APPLE__
#include <dlfcn.h>
#endif

/** Any patches required by the running environment for consistent behavior */
static void patch_env(void) {
#ifdef __APPLE__
  /* patch for dealing with the High Sierra `fork` limitations */
  void *obj_c_runtime = dlopen("Foundation.framework/Foundation", RTLD_LAZY);
  (void)obj_c_runtime;
#endif
}

/* *****************************************************************************
Constants and State
***************************************************************************** */

VALUE IodineModule;
VALUE IodineBaseModule;
static ID call_id;

/* *****************************************************************************
Idling
***************************************************************************** */

static fio_lock_i iodine_on_idle_lock = FIO_LOCK_INIT;
static fio_ls_s iodine_on_idle_list = FIO_LS_INIT(iodine_on_idle_list);

static void iodine_perform_deferred(void *block, void *ignr) {
  IodineCaller.call((VALUE)block, call_id);
  (void)ignr;
}

/**
Schedules a single occuring event for the next idle cycle.

To schedule a reoccuring event, simply reschedule the event at the end of it's
run.

i.e.

      IDLE_PROC = Proc.new { puts "idle"; Iodine.on_idle &IDLE_PROC }
      Iodine.on_idle &IDLE_PROC
*/
VALUE iodine_sched_on_idle(VALUE self) {
  rb_need_block();
  VALUE block = rb_block_proc();
  IodineStore.add(block);
  fio_lock(&iodine_on_idle_lock);
  fio_ls_push(&iodine_on_idle_list, (void *)block);
  fio_unlock(&iodine_on_idle_lock);
  return block;
  (void)self;
}

static void iodine_on_idle(void *arg) {
  (void)arg;
  fio_lock(&iodine_on_idle_lock);
  while (fio_ls_any(&iodine_on_idle_list)) {
    VALUE block = (VALUE)fio_ls_shift(&iodine_on_idle_list);
    fio_defer(iodine_perform_deferred, (void *)block, NULL);
    IodineStore.remove(block);
  }
  fio_unlock(&iodine_on_idle_lock);
}

/* *****************************************************************************
Running Iodine
***************************************************************************** */

typedef struct {
  int16_t threads;
  int16_t workers;
} iodine_start_params_s;

static void *iodine_run_outside_GVL(void *params_) {
  iodine_start_params_s *params = params_;
  fio_start(.threads = params->threads, .workers = params->workers);
  return NULL;
}

/* *****************************************************************************
Core API
***************************************************************************** */

/**
 * Returns the number of worker threads that will be used when {Iodine.start}
 * is called.
 *
 * Negative numbers are translated as fractions of the number of CPU cores.
 * i.e., -2 == half the number of detected CPU cores.
 *
 * Zero values promise nothing (iodine will decide what to do with them).
 */
static VALUE iodine_threads_get(VALUE self) {
  VALUE i = rb_ivar_get(self, rb_intern2("@threads", 8));
  if (i == Qnil)
    i = INT2NUM(0);
  return i;
}

/**
 * Sets the number of worker threads that will be used when {Iodine.start}
 * is called.
 *
 * Negative numbers are translated as fractions of the number of CPU cores.
 * i.e., -2 == half the number of detected CPU cores.
 *
 * Zero values promise nothing (iodine will decide what to do with them).
 */
static VALUE iodine_threads_set(VALUE self, VALUE val) {
  Check_Type(val, T_FIXNUM);
  if (NUM2SSIZET(val) >= (1 << 12)) {
    rb_raise(rb_eRangeError, "requsted thread count is out of range.");
  }
  rb_ivar_set(self, rb_intern2("@threads", 8), val);
  return val;
}

/**
 *Returns the number of worker processes that will be used when {Iodine.start}
 * is called.
 *
 * Negative numbers are translated as fractions of the number of CPU cores.
 * i.e., -2 == half the number of detected CPU cores.
 *
 * Zero values promise nothing (iodine will decide what to do with them).
 */
static VALUE iodine_workers_get(VALUE self) {
  VALUE i = rb_ivar_get(self, rb_intern2("@workers", 8));
  if (i == Qnil)
    i = INT2NUM(0);
  return i;
}

/**
 * Sets the number of worker processes that will be used when {Iodine.start}
 * is called.
 *
 * Negative numbers are translated as fractions of the number of CPU cores.
 * i.e., -2 == half the number of detected CPU cores.
 *
 * Zero values promise nothing (iodine will decide what to do with them).
 */
static VALUE iodine_workers_set(VALUE self, VALUE val) {
  Check_Type(val, T_FIXNUM);
  if (NUM2SSIZET(val) >= (1 << 9)) {
    rb_raise(rb_eRangeError, "requsted worker process count is out of range.");
  }
  rb_ivar_set(self, rb_intern2("@workers", 8), val);
  return val;
}

/** Prints the Iodine startup message */
static void iodine_print_startup_message(iodine_start_params_s params) {
  VALUE iodine_version = rb_const_get(IodineModule, rb_intern("VERSION"));
  VALUE ruby_version = rb_const_get(IodineModule, rb_intern("RUBY_VERSION"));
  fio_expected_concurrency(&params.threads, &params.workers);
  fprintf(stderr,
          "\nStarting up Iodine:\n"
          " * Iodine %s\n * Ruby %s\n * facil.io " FIO_VERSION_STRING " (%s)\n"
          " * %d Workers X %d Threads per worker.\n"
          "\n",
          StringValueCStr(iodine_version), StringValueCStr(ruby_version),
          fio_engine(), params.workers, params.threads);
  (void)params;
}

/**
 * This will block the calling (main) thread and start the Iodine reactor.
 *
 * When using cluster mode (2 or more worker processes), it is important that no
 * other threads are active.
 *
 * For many reasons, `fork` should NOT be called while multi-threading, so
 * cluster mode must always be initiated from the main thread in a single thread
 * environment.
 *
 * For information about why forking in multi-threaded environments should be
 * avoided, see (for example):
 * http://www.linuxprogrammingblog.com/threads-and-fork-think-twice-before-using-them
 *
 */
static VALUE iodine_start(VALUE self) {
  if (fio_is_running()) {
    rb_raise(rb_eRuntimeError, "Iodine already running!");
  }
  IodineCaller.set_GVL(1);
  VALUE threads_rb = iodine_threads_get(self);
  VALUE workers_rb = iodine_workers_get(self);
  iodine_start_params_s params = {
      .threads = NUM2SHORT(threads_rb),
      .workers = NUM2SHORT(workers_rb),
  };
  iodine_print_startup_message(params);
  IodineCaller.leaveGVL(iodine_run_outside_GVL, &params);
  return self;
}

/**
 * This will stop the iodine server, shutting it down.
 *
 * If called within a worker process (rather than the root/master process), this
 * will cause a hot-restart for the worker.
 */
static VALUE iodine_stop(VALUE self) {
  fio_stop();
  return self;
}

/* *****************************************************************************
Ruby loads the library and invokes the Init_<lib_name> function...

Here we connect all the C code to the Ruby interface, completing the bridge
between Lib-Server and Ruby.
***************************************************************************** */
void Init_iodine(void) {
  // load any environment specific patches
  patch_env();

  // force the GVL state for the main thread
  IodineCaller.set_GVL(1);

  // Create the Iodine module (namespace)
  IodineModule = rb_define_module("Iodine");
  IodineBaseModule = rb_define_module_under(IodineModule, "Base");
  call_id = rb_intern2("call", 4);

  // register core methods
  rb_define_module_function(IodineModule, "threads", iodine_threads_get, 0);
  rb_define_module_function(IodineModule, "threads=", iodine_threads_set, 1);
  rb_define_module_function(IodineModule, "workers", iodine_workers_get, 0);
  rb_define_module_function(IodineModule, "workers=", iodine_workers_set, 1);
  rb_define_module_function(IodineModule, "start", iodine_start, 0);
  rb_define_module_function(IodineModule, "stop", iodine_stop, 0);
  rb_define_module_function(IodineModule, "on_idle", iodine_sched_on_idle, 0);

  // initialize Object storage for GC protection
  iodine_storage_init();

  // initialize concurrency related methods
  iodine_defer_initialize();

  // initialize the connection class
  iodine_connection_init();

  // intialize the TCP/IP related module
  iodine_init_tcp_connections();

  // initialize the HTTP module
  iodine_init_http();

  // initialize JSON helpers
  iodine_init_json();

  // initialize Mustache engine
  iodine_init_mustache();

  // initialize Rack helpers and IO
  iodine_init_helpers();
  IodineRackIO.init();

  // initialize Pub/Sub extension (for Engines)
  iodine_pubsub_init();

  // register idle and finish callbacks
  fio_state_callback_add(FIO_CALL_ON_IDLE, iodine_on_idle, NULL);
}
