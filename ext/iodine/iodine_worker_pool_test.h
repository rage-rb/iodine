/*
Test helpers for Iodine::WorkerPool.
Provides a busy() class method for testing GVL release and cancellation.
*/

#ifndef H_IODINE_WORKER_POOL_TEST_H
#define H_IODINE_WORKER_POOL_TEST_H

#include <ruby.h>

/**
 * Initializes test methods on the WorkerPool class.
 * Called from iodine_worker_pool_init() when HAVE_IODINE_WORKER_POOL is defined.
 *
 * @param WorkerPoolKlass The Iodine::WorkerPool class
 */
void iodine_worker_pool_test_init(VALUE WorkerPoolKlass);

#endif
