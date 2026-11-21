/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ROOT_LAYOUT_H
#define ERX_FIASCO_ROOT_LAYOUT_H

#include <stdint.h>

#include <l4/sys/consts.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/service_wire.h"

/*
 * The root's layout plan: where the root's capability slots lie past Fiasco's base
 * capabilities, numbered on from the thread table's runs, which thread.h declares, and the
 * IRQ slot of a handle table's entry in every task's. It names Fiasco's base capabilities, so
 * only the backend's own sources and its guests include it; the thread table's header,
 * which musl's seam includes, stays free of Fiasco's headers.
 */

/*
 * The facts the plan starts from are the ABI's (abi/erx_abi.txt): ERX_FIASCO_OBJ_SPACE_SLOTS,
 * the slots of Fiasco's object space under config/fiasco/kernel.defconfig, a two-level
 * table of 512 directory entries of 128 slots each, whose slot ERX_FIASCO_OBJ_SPACE_SLOTS
 * is the first a lookup refuses (docs/design-fiasco.md, "Handles"); ERX_FIASCO_ROOT_HANDLES,
 * the root's handle limit, a declared figure, since what the system domain holds at once
 * is its policy's; and ERX_FIASCO_IRQS_MAX, the IRQ objects the machine holds at once,
 * each with a slot of the root's.
 */

/* The slot of erx_fiasco_thread_semaphore_cap(0), the first past Fiasco's base capabilities. */
#define ERX_FIASCO_SLOT_FIRST	((uint32_t)(L4_BASE_CAPS_LAST >> L4_CAP_SHIFT) + 1u)
/*
 * The IRQ slot of a handle table's entry 0, the same in every task: the first slot past
 * the per-thread runs, the semaphores and then the threads. Entry i's is the base plus i,
 * which erx_fiasco_irq_slot_cap gives.
 */
#define ERX_FIASCO_IRQ_SLOT_BASE	(ERX_FIASCO_SLOT_FIRST + 2u * ERX_FIASCO_THREADS_MAX)
/*
 * The most cap_limit erx_space_create takes: it counts ERX_CAP_NULL, which has no slot,
 * so the last entry's IRQ slot is the object space's last.
 */
#define ERX_FIASCO_CAP_LIMIT_MAX	(ERX_FIASCO_OBJ_SPACE_SLOTS - ERX_FIASCO_IRQ_SLOT_BASE + 1u)

/*
 * The root's layout past both per-thread runs, as erx_fiasco_root_slot_cap numbers its
 * slots: its numbering continues the thread capabilities', so the first is the IRQ slot
 * base. The root's window of IRQ slots, one for each entry of its handle table, then its
 * service gate and thread, the watchdog's slot, one slot for each IRQ object of the
 * machine's, which irq.c keeps, and the slot pool, which service_task.c takes pairs of.
 * One list, so that no two users can pick the same slot.
 */
enum {
	ERX_FIASCO_SLOT_ROOT_WINDOW = ERX_FIASCO_THREADS_MAX,
	ERX_FIASCO_SLOT_SERVICE_GATE = ERX_FIASCO_SLOT_ROOT_WINDOW + ERX_FIASCO_ROOT_HANDLES,
	ERX_FIASCO_SLOT_SERVICE_THREAD,
	ERX_FIASCO_SLOT_WATCHDOG,
	ERX_FIASCO_SLOT_IRQS,
	ERX_FIASCO_SLOT_POOL = ERX_FIASCO_SLOT_IRQS + ERX_FIASCO_IRQS_MAX
};

/*
 * The slot pool's pairs: every slot from the pool's first to the end of the object
 * space, two a pair, an odd last slot unused. Derived, never written down, so no part of
 * the plan can overlap another.
 */
#define ERX_FIASCO_POOL_PAIRS	((ERX_FIASCO_OBJ_SPACE_SLOTS - (ERX_FIASCO_SLOT_FIRST + ERX_FIASCO_THREADS_MAX + \
	    ERX_FIASCO_SLOT_POOL)) / 2u)

/*
 * The pool's shares: two pairs for each row the task table can hold, held back whole, the
 * first of the pool's pairs; the rest the threads', one pair each.
 */
#define ERX_FIASCO_POOL_TASK_PAIRS	(2u * ERX_FIASCO_TASK_ROWS)
#define ERX_FIASCO_POOL_THREAD_PAIRS	(ERX_FIASCO_POOL_PAIRS - ERX_FIASCO_POOL_TASK_PAIRS)

_Static_assert(ERX_FIASCO_SLOT_FIRST + ERX_FIASCO_THREADS_MAX + ERX_FIASCO_SLOT_POOL < ERX_FIASCO_OBJ_SPACE_SLOTS,
    "the root's fixed slots lie within Fiasco's object space");
_Static_assert(ERX_FIASCO_POOL_PAIRS <= UINT16_MAX, "a pair's number, its index plus one, fits the 16 bits of erx_slot_pair_t");
_Static_assert(ERX_FIASCO_POOL_PAIRS > ERX_FIASCO_POOL_TASK_PAIRS,
    "the pool holds two pairs for every row the task table can hold");
_Static_assert(ERX_FIASCO_CAP_LIMIT_MAX <= ERX_CAPS_MAX, "a window's bound is within erXos's own");
_Static_assert(ERX_FIASCO_CAP_LIMIT_MAX >= ERX_PROGRAM_CAP_LIMIT,
    "a program's image table, made with erx_space_cap_limit_max, holds at least program_cap_limit");

uint64_t	erx_fiasco_root_slot_cap(uint32_t);
/*
 * The IRQ slot of a handle table's entry, in every task's object space alike: the
 * capability the root places there for an IRQ entry is what the holder triggers and acks.
 */
uint64_t	erx_fiasco_irq_slot_cap(uint32_t index);

#endif /* ERX_FIASCO_ROOT_LAYOUT_H */
