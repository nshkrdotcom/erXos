/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "liberx/backend/core/mem.h"

#include "bench_clock.h"

void
erx_bench_rounds_a(erx_bench_token_t *token, uint64_t (*read)(void),
    erx_bench_round_t *rounds, size_t n)
{
	uint64_t number = atomic_load_explicit(&token->sent, memory_order_relaxed);

	for (size_t i = 0; i < n; i++) {
		const uint64_t a = read();

		number++;
		atomic_store_explicit(&token->sent, number, memory_order_release);
		while (atomic_load_explicit(&token->answered, memory_order_acquire) != number)
			;
		const uint64_t c = read();
		const uint64_t b = atomic_load_explicit(&token->b, memory_order_relaxed);

		rounds[i] = (erx_bench_round_t){ .a = a, .b = b, .c = c };
	}
}

void
erx_bench_rounds_b(erx_bench_token_t *token, uint64_t (*read)(void), size_t n)
{
	for (size_t i = 0; i < n; i++) {
		uint64_t number;

		do
			number = atomic_load_explicit(&token->sent, memory_order_acquire);
		while (number == atomic_load_explicit(&token->answered, memory_order_relaxed));
		atomic_store_explicit(&token->b, read(), memory_order_relaxed);
		atomic_store_explicit(&token->answered, number, memory_order_release);
	}
}

/* What one round's causality allows the offset to be. */
static void
round_bounds(const erx_bench_round_t *round, int64_t *low, int64_t *high)
{
	*low = (int64_t)round->b - (int64_t)round->c;
	*high = (int64_t)round->b - (int64_t)round->a;
}

erx_bench_offset_t
erx_bench_offset(const erx_bench_round_t *rounds, size_t n, uint64_t increment)
{
	erx_bench_offset_t offset = { .low = INT64_MIN, .high = INT64_MAX };
	int64_t low, high;

	for (size_t i = 0; i < n; i++) {
		round_bounds(&rounds[i], &low, &high);
		offset.low = low > offset.low ? low : offset.low;
		offset.high = high < offset.high ? high : offset.high;
	}
	if (n == 0)
		return ((erx_bench_offset_t){ .empty = true });
	offset.low -= (int64_t)increment;
	offset.high += (int64_t)increment;
	offset.empty = offset.low > offset.high;
	return (offset);
}

uint64_t
erx_bench_offset_half_width(erx_bench_offset_t offset)
{
	uint64_t width = (uint64_t)offset.high - (uint64_t)offset.low;

	return (width / 2 + (width & 1));
}

erx_bench_offset_t
erx_bench_offset_hull(erx_bench_offset_t before, erx_bench_offset_t after)
{
	erx_bench_offset_t hull = { .empty = false };

	if (before.empty || after.empty)
		return ((erx_bench_offset_t){ .empty = true });
	hull.low = before.low < after.low ? before.low : after.low;
	hull.high = before.high > after.high ? before.high : after.high;
	return (hull);
}

const char *
erx_bench_cell_unsupported(bool two_cpus, erx_bench_offset_t before,
    erx_bench_offset_t after, uint64_t median)
{
	if (!two_cpus)
		return (NULL);
	if (before.empty || after.empty)
		return ("counters across CPUs contradicted each other");
	if (before.low > after.high || after.low > before.high)
		return ("counters across CPUs moved during the run");
	if (erx_bench_offset_half_width(erx_bench_offset_hull(before, after)) > median / 10)
		return ("counters across CPUs not bounded closely enough");
	return (NULL);
}

void
erx_bench_read_pairs(uint64_t (*read)(void), erx_bench_reads_t *pairs, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		pairs[i].first = read();
		pairs[i].second = read();
	}
}

erx_bench_read_cal_t
erx_bench_read_calibration(const erx_bench_reads_t *pairs, size_t n, erx_bench_hist_t *deltas)
{
	erx_bench_read_cal_t cal = { 0, 0 };

	bzero(deltas, sizeof(*deltas));
	for (size_t i = 0; i < n; i++) {
		/* One CPU's counter never goes back, so the difference is the read's cost. */
		uint64_t delta = pairs[i].second - pairs[i].first;

		erx_bench_hist_add(deltas, delta);
		if (delta != 0 && (cal.increment == 0 || delta < cal.increment))
			cal.increment = delta;
	}
	cal.read_cost = erx_bench_hist_median(deltas);
	return (cal);
}
