/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A host driver for liberx/backend/core/slot_pool.c. For runs of several sizes, a
 * multiple of 64 and not, from index 0 and past it, it takes pairs until the run is
 * exhausted, expecting distinct pairs lowest first and then a refusal; frees one in the
 * middle and expects it taken next; frees the last pair and expects it taken again; and
 * refuses a free of none, of a free pair and of a pair outside the run, with the free
 * count unchanged. A free leaves its pair naming none. Prints "ok: N checks" or fails
 * with the case and what disagreed.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "liberx/backend/core/slot_pool.h"

#define PAIRS_MAX	200u

static const char	*current_case = "none";
static uint32_t		 checks;

static void
check(bool ok, const char *what, uint64_t detail)
{
	checks++;
	if (!ok) {
		fprintf(stderr, "%s: %s (%llu)\n", current_case, what, (unsigned long long)detail);
		exit(1);
	}
}

static erx_slot_pair_t
take(erx_slot_pool_t *pool, const char *what)
{
	erx_slot_pair_t pair = { .number = 0 };

	check(erx_slot_pool_take(pool, &pair), what, erx_slot_pool_free_count(pool));
	return (pair);
}

/* The pair of the run's index, by number. */
static erx_slot_pair_t
pair_at(uint32_t first, uint32_t index)
{
	return ((erx_slot_pair_t){ .number = (uint16_t)(first + index + 1) });
}

static void
give_back(erx_slot_pool_t *pool, erx_slot_pair_t pair, const char *what)
{
	check(erx_slot_pool_free(pool, &pair), what, pair.number);
	check(pair.number == 0, "a free left its pair naming one", pair.number);
}

static void
exhaust(uint32_t first, uint32_t pairs)
{
	uint64_t taken[ERX_SLOT_POOL_WORDS(PAIRS_MAX)];
	erx_slot_pool_t pool;
	erx_slot_pair_t pair;

	erx_slot_pool_init(&pool, taken, first, pairs);
	check(erx_slot_pool_free_count(&pool) == pairs, "a new pool is not all free", pairs);
	for (uint32_t index = 0; index < pairs; index++) {
		pair = take(&pool, "the exhausting run ended a pair early");
		check(pair.number == pair_at(first, index).number, "two takes answered the same pair, or not lowest first",
		    pair.number);
		check(erx_slot_pool_free_count(&pool) == pairs - index - 1, "a take did not count", index);
	}
	pair = (erx_slot_pair_t){ .number = 7 };
	check(!erx_slot_pool_take(&pool, &pair), "an exhausted pool gave a pair", pair.number);
	check(pair.number == 7, "a refused take changed its pair", pair.number);

	current_case = "a freed pair is taken next";
	give_back(&pool, pair_at(first, pairs / 2), "a taken pair's free refused");
	check(erx_slot_pool_free_count(&pool) == 1, "a free did not count", 0);
	check(take(&pool, "the freed pair was not taken").number == pair_at(first, pairs / 2).number,
	    "the freed pair was not taken next", pairs / 2);

	current_case = "the last pair is taken again";
	give_back(&pool, pair_at(first, pairs - 1), "the last pair's free refused");
	check(take(&pool, "the last pair was not taken again").number == pair_at(first, pairs - 1).number,
	    "the last pair was not taken again", pairs - 1);

	current_case = "a free of what is not taken";
	give_back(&pool, pair_at(first, 0), "the first pair's free refused");
	pair = pair_at(first, 0);
	check(!erx_slot_pool_free(&pool, &pair), "a free pair freed twice", pair.number);
	pair = pair_at(first, pairs);
	check(!erx_slot_pool_free(&pool, &pair), "a pair past the run freed", pair.number);
	pair = (erx_slot_pair_t){ .number = 0 };
	check(!erx_slot_pool_free(&pool, &pair), "none freed", 0);
	if (first > 0) {
		pair = pair_at(0, first - 1);
		check(!erx_slot_pool_free(&pool, &pair) && pair.number == first, "a pair before the run freed", first);
	}
	check(erx_slot_pool_free_count(&pool) == 1, "a refused free counted", erx_slot_pool_free_count(&pool));
	check(!erx_slot_pool_taken(&pool, (erx_slot_pair_t){ .number = 0 }), "none reads as taken", 0);
}

int
main(void)
{
	static const uint32_t sizes[] = { 64, 1, 63, 65, 128, 131, PAIRS_MAX };

	for (size_t size = 0; size < sizeof(sizes) / sizeof(sizes[0]); size++)
		for (uint32_t first = 0; first <= 100; first += 100) {
			current_case = "the exhausting run";
			exhaust(first, sizes[size]);
		}
	printf("ok: %u checks\n", checks);
	return (0);
}
