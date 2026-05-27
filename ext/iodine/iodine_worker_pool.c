/*
Iodine WorkerPool - A thread pool for executing blocking operations
without holding the GVL, used by Ruby's Fiber Scheduler.

Based on io-event worker_pool.c by Samuel Williams.

Requires Ruby 4.0+ for blocking_operation APIs.
*/

#include "iodine.h"

#ifdef HAVE_IODINE_WORKER_POOL

#include "iodine_store.h"
#include "iodine_worker_pool_test.h"

#include <ruby/thread.h>
#include <ruby/fiber/scheduler.h>

#include <pthread.h>
#include <stdbool.h>

static ID call_id;
static ID workers_id;
static ID queued_id;
static ID submitted_id;
static ID in_progress_id;
static ID completed_id;
static ID closed_id;

/* *****************************************************************************
Data Structures
***************************************************************************** */

struct iodine_worker_pool_worker;
struct iodine_worker_pool_work;
struct iodine_worker_pool;

struct iodine_worker_pool_worker {
  VALUE thread;
  bool interrupted;
  rb_fiber_scheduler_blocking_operation_t *current_op;
  struct iodine_worker_pool *pool;
  struct iodine_worker_pool_worker *next;
};

struct iodine_worker_pool_work {
  rb_fiber_scheduler_blocking_operation_t *blocking_operation;
  VALUE callback; /* Block to call when complete */
  struct iodine_worker_pool_work *next;
};

struct iodine_worker_pool {
  pthread_mutex_t mutex;
  pthread_cond_t work_available;

  /* Pending work queue */
  struct iodine_worker_pool_work *work_head;
  struct iodine_worker_pool_work *work_tail;

  struct iodine_worker_pool_worker *workers;
  size_t worker_count;
  size_t max_workers;
  volatile size_t submitted_count;   /* Total tasks enqueued */
  volatile size_t in_progress_count; /* Tasks currently being executed */
  volatile size_t completed_count;   /* Total tasks completed */

  bool initialized;
  bool shutdown;
};

static VALUE WorkerPoolKlass;

/* *****************************************************************************
Queue Operations
***************************************************************************** */

static void enqueue_work(struct iodine_worker_pool *pool,
                         struct iodine_worker_pool_work *work) {
  if (pool->work_tail) {
    pool->work_tail->next = work;
  } else {
    pool->work_head = work;
  }
  pool->work_tail = work;
}

static struct iodine_worker_pool_work *dequeue_work(struct iodine_worker_pool *pool) {
  struct iodine_worker_pool_work *work = pool->work_head;
  if (work) {
    pool->work_head = work->next;
    if (!pool->work_head) {
      pool->work_tail = NULL;
    }
    work->next = NULL;
  }
  return work;
}

/* *****************************************************************************
Worker Thread Functions
***************************************************************************** */

/* Deferred callback - runs on reactor thread to resume fiber */
static void worker_pool_deferred_callback(void *arg, void *ignore) {
  struct iodine_worker_pool_work *work = arg;

  IodineCaller.call(work->callback, call_id);

  IodineStore.remove(work->callback);
  fio_free(work);
  (void)ignore;
}

/* Signal completion from worker thread */
static void worker_pool_complete(struct iodine_worker_pool *pool,
                                 struct iodine_worker_pool_work *work) {
  fio_atomic_sub(&pool->in_progress_count, 1);
  fio_atomic_add(&pool->completed_count, 1);
  fio_defer(worker_pool_deferred_callback, work, NULL);
}

/* Called to interrupt a blocked worker (e.g., on shutdown or Thread#kill) */
static void worker_unblock_func(void *_worker) {
  struct iodine_worker_pool_worker *worker = _worker;
  struct iodine_worker_pool *pool = worker->pool;

  pthread_mutex_lock(&pool->mutex);
  worker->interrupted = true;
  rb_fiber_scheduler_blocking_operation_t *op = worker->current_op;
  pthread_cond_broadcast(&pool->work_available);
  pthread_mutex_unlock(&pool->mutex);

  /* Cancel outside the lock to avoid potential deadlock
     (cancel may trigger callbacks or signal handlers) */
  if (op) {
    rb_fiber_scheduler_blocking_operation_cancel(op);
  }
}

#define WORKER_INTERRUPTED ((void *)-1)

/* Runs without GVL - waits for work and executes it */
static void *worker_wait_and_execute(void *_worker) {
  struct iodine_worker_pool_worker *worker = _worker;
  struct iodine_worker_pool *pool = worker->pool;

  struct iodine_worker_pool_work *work = NULL;

  pthread_mutex_lock(&pool->mutex);

  /* Wait for work, shutdown, or interruption */
  while (!pool->work_head && !pool->shutdown && !worker->interrupted) {
    pthread_cond_wait(&pool->work_available, &pool->mutex);
  }

  if (pool->shutdown) {
    pthread_mutex_unlock(&pool->mutex);
    return NULL; /* Real shutdown signal */
  }

  if (worker->interrupted) {
    worker->interrupted = false;
    pthread_mutex_unlock(&pool->mutex);
    return WORKER_INTERRUPTED; /* Soft interrupt */
  }

  work = dequeue_work(pool);

  /* Set current_op under the lock so worker_unblock_func can safely read it */
  if (work) {
    fio_atomic_add(&pool->in_progress_count, 1);
    worker->current_op = work->blocking_operation;
  }
  pthread_mutex_unlock(&pool->mutex);

  if (work) {
    rb_fiber_scheduler_blocking_operation_execute(work->blocking_operation);
  }

  pthread_mutex_lock(&pool->mutex);
  worker->current_op = NULL;
  pthread_mutex_unlock(&pool->mutex);

  return work;
}

/* Ruby thread entry point */
static VALUE worker_thread_func(void *_worker) {
  struct iodine_worker_pool_worker *worker = _worker;
  struct iodine_worker_pool *pool = worker->pool;

  while (true) {
    struct iodine_worker_pool_work *work =
      rb_thread_call_without_gvl(worker_wait_and_execute,
                                 worker, worker_unblock_func, worker);

    if (!work) {
      /* Shutdown signal */
      break;
    }

    if (work == WORKER_INTERRUPTED) {
      /* Soft interrupt occurred - the VM will process signals now that GVL is
         held. Loop back and wait for work again. */
      continue;
    }

    worker_pool_complete(pool, work);
  }

  return Qnil;
}

/* *****************************************************************************
Pool Lifecycle
***************************************************************************** */

static void worker_pool_mark(void *ptr) {
  struct iodine_worker_pool *pool = ptr;

  /* Mark all worker thread objects as movable for GC compaction.
     The workers list is only modified at init and shutdown,
     so it's safe to traverse without a lock during normal operation. */
  struct iodine_worker_pool_worker *worker = pool->workers;
  while (worker) {
    rb_gc_mark_movable(worker->thread);
    worker = worker->next;
  }

  /* Callbacks are protected via IodineStore */
}

static void worker_pool_compact(void *ptr) {
  struct iodine_worker_pool *pool = ptr;

  /* Update thread references after GC compaction relocates them */
  struct iodine_worker_pool_worker *worker = pool->workers;
  while (worker) {
    worker->thread = rb_gc_location(worker->thread);
    worker = worker->next;
  }
}

static void worker_pool_free(void *ptr) {
  struct iodine_worker_pool *pool = ptr;

  if (pool->initialized && !pool->shutdown) {
    pthread_mutex_lock(&pool->mutex);
    pool->shutdown = true;
    pthread_cond_broadcast(&pool->work_available);
    pthread_mutex_unlock(&pool->mutex);
  }

  /* We don't join threads here as it can deadlock during GC.
     Workers will see shutdown flag and exit cleanly. */
}

static size_t worker_pool_size(const void *ptr) {
  return sizeof(struct iodine_worker_pool);
}

static const rb_data_type_t iodine_worker_pool_type = {
    .wrap_struct_name = "Iodine::WorkerPool",
    .function =
        {
            .dmark = worker_pool_mark,
            .dfree = worker_pool_free,
            .dsize = worker_pool_size,
            .dcompact = worker_pool_compact,
        },
};

static VALUE worker_pool_allocate(VALUE klass) {
  struct iodine_worker_pool *pool;
  VALUE self = TypedData_Make_Struct(klass, struct iodine_worker_pool,
                                     &iodine_worker_pool_type, pool);
  memset(pool, 0, sizeof(*pool));
  pool->shutdown = true;
  pool->initialized = false;
  return self;
}

/* *****************************************************************************
Ruby Methods
***************************************************************************** */

/* Helper to create a worker thread */
static int create_worker(VALUE self, struct iodine_worker_pool *pool) {
  if (pool->worker_count >= pool->max_workers) {
    return -1;
  }

  struct iodine_worker_pool_worker *worker = fio_malloc(sizeof(*worker));
  FIO_ASSERT_ALLOC(worker);

  worker->pool = pool;
  worker->interrupted = false;
  worker->current_op = NULL;
  worker->next = pool->workers;

  worker->thread = rb_thread_create(worker_thread_func, worker);
  if (NIL_P(worker->thread)) {
    fio_free(worker);
    return -1;
  }

  pool->workers = worker;
  pool->worker_count++;

  return 0;
  (void)self;
}

/* Forward declaration for use in initialize */
static VALUE worker_pool_close(VALUE self);

/**
 * Iodine::WorkerPool.new(size)
 *
 * Creates a new worker pool with `size` threads for executing
 * blocking operations without holding the GVL.
 */
static VALUE worker_pool_initialize(VALUE self, VALUE size) {
  Check_Type(size, T_FIXNUM);
  long requested = NUM2LONG(size);

  if (requested <= 0) {
    rb_raise(rb_eArgError, "pool size must be greater than 0");
  }

  size_t max_workers = (size_t)requested;

  struct iodine_worker_pool *pool;
  TypedData_Get_Struct(self, struct iodine_worker_pool,
                       &iodine_worker_pool_type, pool);

  pthread_mutex_init(&pool->mutex, NULL);
  pthread_cond_init(&pool->work_available, NULL);
  pool->initialized = true;
  pool->max_workers = max_workers;
  pool->shutdown = false;

  IodineStore.add(self);

  for (size_t i = 0; i < max_workers; i++) {
    if (create_worker(self, pool) != 0) {
      worker_pool_close(self);
      rb_raise(rb_eRuntimeError, "failed to create worker thread %zu", i);
    }
  }

  return self;
}

/**
 * pool.enqueue(blocking_operation) { fiber.resume }
 *
 * Enqueues a blocking operation to be executed on a background thread.
 * The block is called (with GVL held) after the operation completes.
 *
 * @param blocking_operation [Object] The blocking operation from Ruby VM
 * @yield Called when the operation completes
 */
static VALUE worker_pool_enqueue(VALUE self, VALUE blocking_operation_value) {
  if (!rb_block_given_p()) {
    rb_raise(rb_eArgError, "block required");
  }

  struct iodine_worker_pool *pool;
  TypedData_Get_Struct(self, struct iodine_worker_pool,
                       &iodine_worker_pool_type, pool);

  if (pool->shutdown) {
    rb_raise(rb_eRuntimeError, "Worker pool is shut down");
  }

  rb_fiber_scheduler_blocking_operation_t *blocking_op =
      rb_fiber_scheduler_blocking_operation_extract(blocking_operation_value);

  if (!blocking_op) {
    rb_raise(rb_eArgError, "Invalid blocking operation");
  }

  VALUE callback = rb_block_proc();
  IodineStore.add(callback);

  struct iodine_worker_pool_work *work = fio_malloc(sizeof(*work));
  FIO_ASSERT_ALLOC(work);

  work->blocking_operation = blocking_op;
  work->callback = callback;
  work->next = NULL;

  /* Enqueue work */
  pthread_mutex_lock(&pool->mutex);
  enqueue_work(pool, work);
  pool->submitted_count++;
  pthread_cond_signal(&pool->work_available);
  pthread_mutex_unlock(&pool->mutex);

  return Qtrue;
}

/* Helper to count items in the work queue (must hold mutex) */
static size_t count_queue_size(struct iodine_worker_pool *pool) {
  size_t count = 0;
  struct iodine_worker_pool_work *work = pool->work_head;
  while (work) {
    count++;
    work = work->next;
  }
  return count;
}

/**
 * pool.stats -> Hash
 *
 * Returns statistics about the worker pool.
 *
 * @return [Hash] Statistics hash with the following keys:
 *   - :workers [Integer] Current number of worker threads
 *   - :queued [Integer] Number of tasks waiting in queue
 *   - :submitted [Integer] Total tasks enqueued
 *   - :in_progress [Integer] Tasks currently being executed
 *   - :completed [Integer] Total tasks completed
 *   - :closed [Boolean] Whether the pool is closed
 */
static VALUE worker_pool_statistics(VALUE self) {
  struct iodine_worker_pool *pool;
  TypedData_Get_Struct(self, struct iodine_worker_pool,
                       &iodine_worker_pool_type, pool);

  size_t submitted = pool->submitted_count;
  size_t completed = pool->completed_count;
  bool closed = pool->shutdown;
  size_t in_progress = 0;
  size_t workers = 0;
  size_t queued = 0;

  if (pool->initialized) {
    pthread_mutex_lock(&pool->mutex);
    workers = pool->worker_count;
    in_progress = pool->in_progress_count;
    queued = count_queue_size(pool);
    pthread_mutex_unlock(&pool->mutex);
  }

  VALUE stats = rb_hash_new();
  rb_hash_aset(stats, ID2SYM(workers_id), SIZET2NUM(workers));
  rb_hash_aset(stats, ID2SYM(queued_id), SIZET2NUM(queued));
  rb_hash_aset(stats, ID2SYM(in_progress_id), SIZET2NUM(in_progress));
  rb_hash_aset(stats, ID2SYM(completed_id), SIZET2NUM(completed));
  rb_hash_aset(stats, ID2SYM(submitted_id), SIZET2NUM(submitted));
  rb_hash_aset(stats, ID2SYM(closed_id), closed ? Qtrue : Qfalse);

  return stats;
}

/**
 * pool.close -> nil
 *
 * Closes the worker pool during process shutdown.
 * Queued work items that have not started are discarded and their
 * callbacks are not invoked. Work already executing is not cancelled;
 * close waits for worker threads to return naturally.
 *
 * @note This is intended for teardown only.
 */
static VALUE worker_pool_close(VALUE self) {
  struct iodine_worker_pool *pool;
  TypedData_Get_Struct(self, struct iodine_worker_pool,
                       &iodine_worker_pool_type, pool);

  if (pool->shutdown || !pool->initialized) {
    return Qnil;
  }

  pthread_mutex_lock(&pool->mutex);
  pool->shutdown = true;
  pthread_cond_broadcast(&pool->work_available);
  pthread_mutex_unlock(&pool->mutex);

  /* Join all worker threads */
  struct iodine_worker_pool_worker *worker = pool->workers;
  while (worker) {
    if (!NIL_P(worker->thread)) {
      rb_funcall(worker->thread, rb_intern("join"), 0);
    }
    worker = worker->next;
  }

  /* Free worker structures */
  worker = pool->workers;
  while (worker) {
    struct iodine_worker_pool_worker *next = worker->next;
    fio_free(worker);
    worker = next;
  }
  pool->workers = NULL;
  pool->worker_count = 0;

  /* Free any remaining queued work */
  struct iodine_worker_pool_work *work = pool->work_head;
  while (work) {
    struct iodine_worker_pool_work *next = work->next;
    IodineStore.remove(work->callback);
    fio_free(work);
    work = next;
  }
  pool->work_head = pool->work_tail = NULL;

  pthread_mutex_destroy(&pool->mutex);
  pthread_cond_destroy(&pool->work_available);
  pool->initialized = false;

  IodineStore.remove(self);

  return Qnil;
}

/**
 * pool.size -> Integer
 *
 * Returns the number of worker threads.
 */
static VALUE worker_pool_size_method(VALUE self) {
  struct iodine_worker_pool *pool;
  TypedData_Get_Struct(self, struct iodine_worker_pool,
                       &iodine_worker_pool_type, pool);
  return SIZET2NUM(pool->worker_count);
}

/* *****************************************************************************
Initialization
***************************************************************************** */

void iodine_worker_pool_init(void) {
  call_id = rb_intern("call");

  workers_id = rb_intern("workers");
  queued_id = rb_intern("queued");
  submitted_id = rb_intern("submitted");
  in_progress_id = rb_intern("in_progress");
  completed_id = rb_intern("completed");
  closed_id = rb_intern("closed");

  WorkerPoolKlass = rb_define_class_under(IodineModule, "WorkerPool", rb_cObject);

  rb_define_alloc_func(WorkerPoolKlass, worker_pool_allocate);
  rb_define_method(WorkerPoolKlass, "initialize", worker_pool_initialize, 1);
  rb_define_method(WorkerPoolKlass, "enqueue", worker_pool_enqueue, 1);
  rb_define_method(WorkerPoolKlass, "close", worker_pool_close, 0);
  rb_define_method(WorkerPoolKlass, "size", worker_pool_size_method, 0);
  rb_define_method(WorkerPoolKlass, "stats", worker_pool_statistics, 0);

  /* Initialize test helpers */
  iodine_worker_pool_test_init(WorkerPoolKlass);
}

#else /* !HAVE_IODINE_WORKER_POOL */

/*
 * Stub implementation for Ruby versions without blocking_operation APIs.
 * The WorkerPool class is not available.
 */
void iodine_worker_pool_init(void) {}

#endif /* HAVE_IODINE_WORKER_POOL */
