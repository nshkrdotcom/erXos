/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "bench_hist.h"

unsigned
erx_bench_hist_index(uint64_t value)
{
	unsigned octave;

	if (value < ERX_BENCH_HIST_SUB)
		return ((unsigned)value);
	/* value's top bit, 6 or more; the six bits below it pick the sub-bucket. */
	octave = 63 - (unsigned)__builtin_clzll(value);
	return (ERX_BENCH_HIST_SUB + (octave - 6) * ERX_BENCH_HIST_SUB +
	    (unsigned)((value >> (octave - 6)) & 63));
}

void
erx_bench_hist_bounds(unsigned index, uint64_t *low, uint64_t *last)
{
	unsigned octave, sub;

	if (index < ERX_BENCH_HIST_SUB) {
		*low = *last = index;
		return;
	}
	octave = (index - ERX_BENCH_HIST_SUB) / ERX_BENCH_HIST_SUB + 6;
	sub = (index - ERX_BENCH_HIST_SUB) % ERX_BENCH_HIST_SUB;
	*low = (uint64_t)(ERX_BENCH_HIST_SUB + sub) << (octave - 6);
	*last = *low + ((UINT64_C(1) << (octave - 6)) - 1);
}

void
erx_bench_hist_add(erx_bench_hist_t *hist, uint64_t value)
{
	hist->count[erx_bench_hist_index(value)]++;
	hist->samples++;
}
