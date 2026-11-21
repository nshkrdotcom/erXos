/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/core/slot_pool.h"

/* The pair's place in the run, or the run's size for none and a pair of another run. */
static uint32_t
pair_place(const erx_slot_pool_t *pool, erx_slot_pair_t pair)
{
	const uint32_t place = (uint32_t)pair.number - 1u - pool->first;

	return (pair.number > pool->first && place < pool->pairs ? place : pool->pairs);
}

static uint64_t
pair_bit(const erx_slot_pool_t *pool, erx_slot_pair_t pair)
{
	return (UINT64_C(1) << (pair_place(pool, pair) % 64));
}

void
erx_slot_pool_init(erx_slot_pool_t *pool, uint64_t *taken, uint32_t first, uint32_t pairs)
{
	*pool = (erx_slot_pool_t){ .taken = taken, .first = first, .pairs = pairs, .free = pairs };
	for (uint32_t word = 0; word < ERX_SLOT_POOL_WORDS(pairs); word++)
		taken[word] = 0;
}

/*
 * The first word with a clear bit holds the lowest free pair, unless that bit lies past
 * the last pair, in the last word's spare bits: then every pair is taken.
 */
bool
erx_slot_pool_take(erx_slot_pool_t *pool, erx_slot_pair_t *pair)
{
	for (uint32_t word = 0; word < ERX_SLOT_POOL_WORDS(pool->pairs); word++) {
		if (pool->taken[word] == UINT64_MAX)
			continue;
		const uint32_t index = word * 64 + (uint32_t)__builtin_ctzll(~pool->taken[word]);

		if (index >= pool->pairs)
			return (false);
		*pair = (erx_slot_pair_t){ .number = (uint16_t)(pool->first + index + 1) };
		pool->taken[word] |= pair_bit(pool, *pair);
		pool->free--;
		return (true);
	}
	return (false);
}

bool
erx_slot_pool_taken(const erx_slot_pool_t *pool, erx_slot_pair_t pair)
{
	const uint32_t place = pair_place(pool, pair);

	return (place < pool->pairs && (pool->taken[place / 64] & pair_bit(pool, pair)) != 0);
}

bool
erx_slot_pool_free(erx_slot_pool_t *pool, erx_slot_pair_t *pair)
{
	if (!erx_slot_pool_taken(pool, *pair))
		return (false);
	pool->taken[pair_place(pool, *pair) / 64] &= ~pair_bit(pool, *pair);
	pool->free++;
	*pair = (erx_slot_pair_t){ .number = 0 };
	return (true);
}

uint32_t
erx_slot_pool_free_count(const erx_slot_pool_t *pool)
{
	return (pool->free);
}
