/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "bench_clock.h"

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
	offset.low -= (int64_t)increment;
	offset.high += (int64_t)increment;
	offset.empty = offset.low > offset.high;
	return (offset);
}

uint64_t
erx_bench_offset_half_width(erx_bench_offset_t offset)
{
	return (((uint64_t)(offset.high - offset.low) + 1) / 2);
}

bool
erx_bench_cell_bounded(bool two_cpus, erx_bench_offset_t before,
    erx_bench_offset_t after, uint64_t median)
{
	erx_bench_offset_t common;

	if (!two_cpus)
		return (true);
	if (before.empty || after.empty)
		return (false);
	common.low = before.low > after.low ? before.low : after.low;
	common.high = before.high < after.high ? before.high : after.high;
	common.empty = common.low > common.high;
	return (!common.empty && erx_bench_offset_half_width(common) * 10 <= median);
}
