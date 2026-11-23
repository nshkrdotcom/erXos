/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_REPLY_SLOTS_H
#define ERX_FIASCO_REPLY_SLOTS_H

#include <stdbool.h>
#include <stdint.h>

/*
 * The root service's reply slots (docs/design-fiasco.md, "Faults, and the fault of the
 * root task"): which of Fiasco's explicit reply slots the next receive fills, and which
 * slots hold a fault that waits for its task's stop. A pure state machine, so the host
 * tests it; service.c does the IPC.
 *
 * Each message arrives in the receive slot, and the service answers from that slot and
 * receives the next message into it, except a fault: its slot is parked with its task,
 * and the receive moves to a free slot, so a receive never fills a slot that still holds
 * a caller. Before each receive the service takes back every slot parked with a task no
 * longer live, whose stop has deleted the faulting thread, and empties it. A zeroed table
 * receives into slot 0 and parks nothing.
 */

/* Room for each faulting thread whose space's server has not stopped it yet, which nothing enforces (docs/todo-fiasco.md). */
#define ERX_FIASCO_REPLY_SLOTS	64u

typedef struct erx_fiasco_reply_slots {
	uint32_t	receive;			/* the slot the next receive fills; never parked */
	uint64_t	parked[ERX_FIASCO_REPLY_SLOTS];	/* each slot's task plus one, or 0 when not parked */
} erx_fiasco_reply_slots_t;

/*
 * The fault that arrived in the receive slot waits for its task's stop: the slot is
 * parked with the task, and the receive moves to a free slot. With every other slot
 * parked the fault is not parked: the next receive takes its slot over, and Fiasco
 * empties it with a warning on the console while the thread stays blocked until its
 * stop.
 */
void	erx_fiasco_reply_park(erx_fiasco_reply_slots_t *slots, uint32_t task);

/*
 * One slot parked with a task that live() no longer finds live, now free, in *slot for
 * the service to empty; false when none is left.
 */
bool	erx_fiasco_reply_take(erx_fiasco_reply_slots_t *slots, bool (*live)(uint32_t task), uint32_t *slot);

#endif /* ERX_FIASCO_REPLY_SLOTS_H */
