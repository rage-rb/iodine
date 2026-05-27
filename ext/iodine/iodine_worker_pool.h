/*
Iodine WorkerPool - A thread pool for executing blocking operations
without holding the GVL, used by Ruby's Fiber Scheduler.

Based on io-event worker_pool.c by Samuel Williams.
*/

#ifndef H_IODINE_WORKER_POOL_H
#define H_IODINE_WORKER_POOL_H

#include <ruby.h>

/**
 * Initializes the Iodine::WorkerPool Ruby class.
 * Called from Init_iodine_ext().
 */
void iodine_worker_pool_init(void);

#endif
