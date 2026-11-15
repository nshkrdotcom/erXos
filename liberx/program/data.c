/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The data area's slots (data.h).  taken has a bit set for each slot a
 * request holds, under lock; a slot is free while its bit is clear, so the
 * area needs no setup beyond program.c's mapping.  A taker that finds no
 * free slot waits on waiters, as a sender waits for a reply slot
 * (channel.c), and every give wakes them, each looking again under the
 * lock.
 */

#include <pthread.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/data.h"
#include "liberx/program/program.h"
#include "liberx/program/wake.h"

_Static_assert(ERX_PROG_DATA_SLOTS_MAX <= 32, "taken holds a bit for each slot");

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t taken;
static erx_prog_waitq_t waiters;

/* The area's slots, as program.c mapped them: whole slots, 1 to ERX_PROG_DATA_SLOTS_MAX. */
static uint32_t
slot_count(void)
{
	return ((uint32_t)(erx_prog_self()->data_bytes / ERX_PROG_DATA_SLOT_BYTES));
}

/* The lowest free slot of all, or all when every one is taken; the caller holds lock. */
static uint32_t
free_slot(uint32_t all)
{
	uint32_t slot;

	for (slot = 0; slot < all && (taken & (UINT32_C(1) << slot)) != 0; slot++)
		continue;
	return (slot);
}

uint32_t
erx_prog_data_take(void)
{
	const uint32_t all = slot_count();
	uint32_t slot;

	(void)pthread_mutex_lock(&lock);
	while ((slot = free_slot(all)) == all) {
		const uint32_t seen = erx_prog_wake_seen();
		erx_prog_waiter_t me;

		erx_prog_waitq_join(&waiters, &me);
		(void)pthread_mutex_unlock(&lock);
		erx_prog_wake_sleep(seen, ERX_WAIT_FOREVER);
		(void)pthread_mutex_lock(&lock);
		erx_prog_waitq_leave(&waiters, &me);
	}
	taken |= UINT32_C(1) << slot;
	(void)pthread_mutex_unlock(&lock);
	return (slot);
}

void
erx_prog_data_give(uint32_t slot)
{
	(void)pthread_mutex_lock(&lock);
	taken &= ~(UINT32_C(1) << slot);
	erx_prog_waitq_wake(&waiters);
	(void)pthread_mutex_unlock(&lock);
}

void *
erx_prog_data_bytes(uint32_t slot)
{
	return ((uint8_t *)erx_prog_self()->data_area + (size_t)slot * ERX_PROG_DATA_SLOT_BYTES);
}
