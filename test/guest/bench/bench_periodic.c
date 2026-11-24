/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "liberx/backend/core/mem.h"

#include "bench_periodic.h"

unsigned
erx_bench_periodic_phase(uint32_t k)
{
	return ((unsigned)(((uint64_t)k * 7) % ERX_BENCH_PHASES));
}

uint64_t
erx_bench_periodic_deadline(uint64_t first, uint64_t period, uint32_t k)
{
	return (first + (uint64_t)k * period +
	    (uint64_t)erx_bench_periodic_phase(k) * period / ERX_BENCH_PHASES);
}

uint32_t
erx_bench_periodic_next(uint64_t first, uint64_t period, uint32_t waited, uint64_t returned)
{
	uint32_t next;

	next = waited + 1;
	while (erx_bench_periodic_deadline(first, period, next) <= returned)
		next++;
	return (next);
}

void
erx_bench_periodic_classify(uint64_t first, uint64_t period, const erx_bench_stamp_t *stamps,
    size_t n, erx_bench_periodic_t *out)
{
	uint64_t deadline, late;
	unsigned phase;

	bzero(out, sizeof(*out));
	out->returns = (uint32_t)n;
	for (phase = 0; phase < ERX_BENCH_PHASES; phase++)
		out->phase_min[phase] = UINT64_MAX;
	if (n == 0)
		return;
	out->missed = stamps[n - 1].k + 1 - (uint32_t)n;
	/* The first pass finds each phase's minimum, the second each return's excess over it. */
	for (size_t i = 0; i < n; i++) {
		deadline = erx_bench_periodic_deadline(first, period, stamps[i].k);
		if (stamps[i].returned < deadline) {
			out->early++;
			continue;
		}
		late = stamps[i].returned - deadline;
		phase = erx_bench_periodic_phase(stamps[i].k);
		if (late < out->phase_min[phase])
			out->phase_min[phase] = late;
		out->phase_returns[phase]++;
		if (late > out->max_late)
			out->max_late = late;
		erx_bench_hist_add(&out->late, late);
	}
	for (size_t i = 0; i < n; i++) {
		deadline = erx_bench_periodic_deadline(first, period, stamps[i].k);
		if (deadline > stamps[i].returned)
			continue;
		phase = erx_bench_periodic_phase(stamps[i].k);
		erx_bench_hist_add(&out->excess,
		    stamps[i].returned - deadline - out->phase_min[phase]);
	}
}
