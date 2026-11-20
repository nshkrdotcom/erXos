/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_THREAD_H
#define ERX_FIASCO_THREAD_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include <l4/sys/consts.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/core/park_table.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/umtx_table.h"

/*
 * The thread table and the thread calls (docs/design-fiasco.md, "Thread
 * creation"). "The task" below is the caller's.
 */

/* What erx_thread_create reads from the head of the caller's public UTCB's mr. */
typedef struct erx_fiasco_start {
	erx_regs_t	regs;
	uint64_t	tls;
} erx_fiasco_start_t;

/*
 * A record's life. CLAIMED is a create in flight, whose kernel objects may not exist
 * yet. Only a start moves CREATED to STARTED, so a start of any other handle touches
 * nothing, the marker least of all: the kernel may already have cleared it, and a
 * stale 1 there would lose the index for good.
 */
typedef enum erx_fiasco_thread_state {
	ERX_FIASCO_THREAD_FREE = 0,
	ERX_FIASCO_THREAD_CLAIMED,
	ERX_FIASCO_THREAD_CREATED,
	ERX_FIASCO_THREAD_STARTED
} erx_fiasco_thread_state_t;

/*
 * A record's size, and the table of them that each task commits at one constant address;
 * after the table, on a page of its own, its home group's entry labels (park.c), which the
 * service's bind writes through the window. Each task commits the area whole.
 */
#define ERX_FIASCO_THREAD_RECORD_BYTES	2048u
#define ERX_FIASCO_THREAD_TABLE_BYTES	((uint64_t)ERX_FIASCO_THREADS_MAX * ERX_FIASCO_THREAD_RECORD_BYTES)
#define ERX_FIASCO_TASK_AREA_BYTES	(ERX_FIASCO_THREAD_TABLE_BYTES + ERX_PAGE_SIZE)

/* The label page: entry n's label at index n, read by the home task with acquire order. */
_Atomic uint64_t *erx_fiasco_labels(void);

/* One thread's record. */
typedef struct erx_fiasco_thread_record {
	erx_utcb_t		utcb;	/* the public UTCB, first */
	erx_fiasco_start_t	start;
	_Atomic uint32_t	used;	/* an erx_fiasco_thread_state_t: claimed under the thread lock */
	uint32_t		index;
	uint64_t		semaphore;	/* the capability, from the create's reply */
	erx_fiasco_umtx_node_t	node;
	uint32_t		executor_slot;	/* its slot in the group, or ERX_BACKEND_PARK_NO_SLOT for a worker */
	uint64_t		clear_word;	/* the reaper stores 0 here and wakes it; 0 for none */
	uint64_t		release_base;	/* a detached thread's range, for the reaper to release */
	uint64_t		release_size;
	struct erx_fiasco_thread_record *reap_next;	/* the reaper's list, under the thread lock */
} erx_fiasco_thread_record_t;

/* The calling thread's record, through its native UTCB's first user word. */
erx_fiasco_thread_record_t *erx_fiasco_thread_self(void);
erx_fiasco_thread_record_t *erx_fiasco_thread_record(uint32_t);
/* The calling thread's public UTCB: the start of its record. */
erx_utcb_t *erx_utcb_self(void);

/* The order of the area holding a task's 128 native UTCB slots. */
#define ERX_FIASCO_UTCB_AREA_ORDER	17u

/* The first thread's own record, once its table's pages and its semaphore exist. */
void		erx_fiasco_thread_first_init(void);

/* Starts the reaper, on the first thread once the service runs. Returns NULL, or why not. */
const char	*erx_fiasco_reaper_start(void);

/*
 * Blocks on a thread's semaphore until an up or the deadline, returning false at
 * the deadline, never before it. Every other IPC error waits again.
 */
bool		erx_fiasco_semaphore_down(uint64_t semaphore, uint64_t deadline);

#ifdef ERX_FIASCO_TEST_HOOKS
/* A semaphore's up, and an IPC receive wait of the given length with nothing to receive. */
void		erx_fiasco_test_semaphore_up(uint64_t);
void		erx_fiasco_test_ipc_sleep_us(uint64_t);
#endif

/*
 * Where each index's native UTCB is in the table's area, and its capabilities in
 * the root. Index 0, the first thread, has the kernel-given UTCB instead, which is
 * why a claim starts at 1.
 */
uint64_t	erx_fiasco_thread_native_slot(uint32_t);
uint64_t	erx_fiasco_thread_semaphore_cap(uint32_t);
uint64_t	erx_fiasco_thread_cap(uint32_t);

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

/* The first thread's kernel-given UTCB: its page holds the service's and the watchdog's too. */
void		*erx_fiasco_thread_first_utcb(void);

/* The trampoline's entry, and the thread pointer as the caller's thread holds it. */
void		erx_fiasco_thread_trampoline(void);
uint64_t	erx_fiasco_thread_pointer(void);

/*
 * The starting registers are in the caller's public UTCB. space 0 is the caller's
 * own task; the root may also name a task with no thread yet, whose first thread this
 * makes. budget and group are ignored, and an executor takes a slot in the task's one
 * group, or ERX_ENOMEM.
 * No free index is ERX_ENOMEM. *thread is the handle.
 */
int	erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class,
	    uint64_t *thread) ERX_WARN_UNUSED_RESULT;
/* Starting a thread twice, or a handle that names none, is ERX_EINVAL. */
int	erx_thread_start(uint64_t thread) ERX_WARN_UNUSED_RESULT;

/*
 * Runs the thread on one CPU of mask, from its start if it has not started: its
 * own if the mask holds it, as Fiasco chooses (scheduler.cpp:98-103). An empty mask,
 * one that names no CPU, or a handle that names no thread is ERX_EINVAL.
 */
int	erx_thread_set_affinity(uint64_t thread, uint64_t mask) ERX_WARN_UNUSED_RESULT;

/*
 * The word the reaper clears and wakes once this thread can no longer run: musl's
 * SYS_set_tid_address names the caller's own handle, its __clone a new thread's.
 * A handle that names no thread is ERX_EINVAL.
 */
int	erx_fiasco_thread_set_clear_word(uint64_t thread, uint64_t word) ERX_WARN_UNUSED_RESULT;

/* Gives the CPU to the next thread of the caller's priority on it, if any. */
void	erx_yield(void);

/* Hands the calling thread to the reaper and never returns. */
_Noreturn void	erx_thread_exit(void);
/* The same for a detached thread, whose stack is this range. */
_Noreturn void	erx_thread_exit_release(uint64_t base, uint64_t size);

#endif /* ERX_FIASCO_THREAD_H */
