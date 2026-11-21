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

/* The most IRQ objects the machine holds at once: each has a slot of the root's. */
#define ERX_FIASCO_IRQS_MAX	256u

/*
 * The capability slots of Fiasco's object space under config/fiasco/kernel.defconfig: a
 * two-level table of 512 directory entries of 128 slots each (docs/design-fiasco.md,
 * "Handles"). Slot ERX_FIASCO_OBJ_SPACE_SLOTS is the first a lookup refuses.
 */
#define ERX_FIASCO_OBJ_SPACE_SLOTS	65536u
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
 * A task's run of the root's slots: its semaphores, its threads, then its gate, its
 * space and its end semaphore, which service_task.c names.
 */
#define ERX_FIASCO_TASK_SLOTS	(2u * ERX_FIASCO_THREADS_MAX + 3u)
/*
 * The most tasks besides the root, each with its run. The object space holds no more
 * than about 250 runs beside the root's own slots, so this, and not the task table,
 * bounds the tasks; the figure is open (TODO.md, the root's layout plan).
 */
#define ERX_FIASCO_TASK_RUNS_MAX	192u
/*
 * The root's handle limit: what the object space leaves once every other part of the
 * root's layout is laid out, the three fixed slots below, the IRQ objects' and the
 * tasks' runs. No figure of its own, so the root's window cannot reach its other slots.
 */
#define ERX_FIASCO_ROOT_HANDLES	(ERX_FIASCO_OBJ_SPACE_SLOTS - ERX_FIASCO_IRQ_SLOT_BASE - 3u - ERX_FIASCO_IRQS_MAX - \
	    ERX_FIASCO_TASK_RUNS_MAX * ERX_FIASCO_TASK_SLOTS)

/*
 * The root's layout past both per-thread runs, as erx_fiasco_root_slot_cap numbers its
 * slots: its numbering continues the thread capabilities', so the first is the IRQ slot
 * base. The root's window of IRQ slots, one for each entry of its handle table, then its
 * service gate and thread, the watchdog's slot, one slot for each IRQ object of the
 * machine's, which irq.c keeps, and each task's run, which service_task.c divides. One
 * list, so that no two users can pick the same slot.
 */
enum {
	ERX_FIASCO_SLOT_ROOT_WINDOW = ERX_FIASCO_THREADS_MAX,
	ERX_FIASCO_SLOT_SERVICE_GATE = ERX_FIASCO_SLOT_ROOT_WINDOW + ERX_FIASCO_ROOT_HANDLES,
	ERX_FIASCO_SLOT_SERVICE_THREAD,
	ERX_FIASCO_SLOT_WATCHDOG,
	ERX_FIASCO_SLOT_IRQS,
	ERX_FIASCO_SLOT_TASK_RUNS = ERX_FIASCO_SLOT_IRQS + ERX_FIASCO_IRQS_MAX,
	ERX_FIASCO_SLOT_END = ERX_FIASCO_SLOT_TASK_RUNS + ERX_FIASCO_TASK_RUNS_MAX * ERX_FIASCO_TASK_SLOTS
};

_Static_assert(ERX_FIASCO_ROOT_HANDLES > 0 && ERX_FIASCO_ROOT_HANDLES < ERX_FIASCO_OBJ_SPACE_SLOTS,
    "the root's layout leaves the root handles");
_Static_assert(ERX_FIASCO_SLOT_FIRST + ERX_FIASCO_THREADS_MAX + ERX_FIASCO_SLOT_END <= ERX_FIASCO_OBJ_SPACE_SLOTS,
    "the root's layout lies within Fiasco's object space");
_Static_assert(ERX_FIASCO_CAP_LIMIT_MAX <= ERX_CAPS_MAX, "a window's bound is within erXos's own");

uint64_t	erx_fiasco_root_slot_cap(uint32_t);
/*
 * The IRQ slot of a handle table's entry, in every task's object space alike: the
 * capability the root places there for an IRQ entry is what the holder triggers and acks.
 */
uint64_t	erx_fiasco_irq_slot_cap(uint32_t index);

#endif /* ERX_FIASCO_ROOT_LAYOUT_H */
