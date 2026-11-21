/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_SLOT_POOL_H
#define ERX_BACKEND_SLOT_POOL_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/cdefs.h"

/*
 * The root's slot pool on Fiasco (docs/design-fiasco.md, "Handles"): the capability
 * slots past the root's fixed ones, counted in pairs, so a count of free pairs is a
 * count of what can be placed. A pool here is one run of those pairs; the root keeps
 * one for the task rows and one for the threads, so neither takes the other's share.
 * A take gives the run's lowest free pair, as the object records are taken; a free
 * gives a taken pair back. The pool is a bit per pair that its caller stores, so it
 * reads no other state, builds for the host and is tested there. Only the root service
 * takes and frees, one body at a time, so nothing here locks.
 */

/*
 * A pair by its number, its index among all the root's pairs plus one, so the zero a
 * cleared record holds is no pair: a record that names none reaches no slot. A type of
 * its own, so no thread or task index passes for one.
 */
typedef struct erx_slot_pair {
	uint16_t	number;
} erx_slot_pair_t;

typedef struct erx_slot_pool {
	uint64_t	*taken;		/* bit n of word n / 64 set while the run's pair n is taken */
	uint32_t	 first;		/* the index of the run's first pair */
	uint32_t	 pairs;
	uint32_t	 free;
} erx_slot_pool_t;

/* The words of taken a run of this many pairs needs. */
#define ERX_SLOT_POOL_WORDS(pairs)	(((pairs) + 63u) / 64u)

/* Every pair of the run from index first free; taken holds ERX_SLOT_POOL_WORDS(pairs) words, and first + pairs is below 65,536. */
void	erx_slot_pool_init(erx_slot_pool_t *, uint64_t *taken, uint32_t first, uint32_t pairs);
/* The run's lowest free pair, marked taken; false, and pair untouched, when none is free. */
bool	erx_slot_pool_take(erx_slot_pool_t *, erx_slot_pair_t *pair) ERX_WARN_UNUSED_RESULT;
/*
 * Gives a pair of the run back and leaves *pair naming none; false, with the pool and
 * *pair unchanged, for none, a pair of another run or a pair that is not taken.
 */
bool	erx_slot_pool_free(erx_slot_pool_t *, erx_slot_pair_t *pair) ERX_WARN_UNUSED_RESULT;
/* Whether pair is the run's and taken. */
bool	erx_slot_pool_taken(const erx_slot_pool_t *, erx_slot_pair_t pair);
uint32_t	erx_slot_pool_free_count(const erx_slot_pool_t *);

#endif /* ERX_BACKEND_SLOT_POOL_H */
