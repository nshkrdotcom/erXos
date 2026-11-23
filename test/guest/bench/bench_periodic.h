/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The periodic profile's schedule and its classification (docs/design-bench.md,
 * "Profiles"), pure functions of the stamps they are given. Deadline k is fixed before the
 * run: the first deadline, plus k periods, plus (7k mod 16) / 16 of a period, which visits
 * sixteen phases in turn. A park waits on the first deadline after the last return, so a
 * stall shows as missed periods and lateness and is never absorbed into the schedule; a
 * return before its deadline is early, which is a wrong answer.
 */

#ifndef ERX_BENCH_PERIODIC_H
#define ERX_BENCH_PERIODIC_H

#include <stddef.h>
#include <stdint.h>

#include "bench_hist.h"

#define	ERX_BENCH_PHASES	16

/* One park: the deadline index it waited on, and the counter when it returned. */
typedef struct {
	uint32_t k;
	uint64_t returned;
} erx_bench_stamp_t;

typedef struct {
	uint32_t returns;
	uint32_t early;
	/* Deadlines before the last waited one that no park waited on. */
	uint32_t missed;
	uint64_t max_late;
	/* The smallest lateness of each phase, UINT64_MAX for a phase with no on-time return. */
	uint64_t phase_min[ERX_BENCH_PHASES];
	uint32_t phase_returns[ERX_BENCH_PHASES];
	/* Every on-time return's lateness, and its excess above its phase's minimum. */
	erx_bench_hist_t late;
	erx_bench_hist_t excess;
} erx_bench_periodic_t;

unsigned erx_bench_periodic_phase(uint32_t k);
uint64_t erx_bench_periodic_deadline(uint64_t first, uint64_t period, uint32_t k);
/* The deadline to wait on after a park on deadline waited returned at returned. */
uint32_t erx_bench_periodic_next(uint64_t first, uint64_t period, uint32_t waited,
    uint64_t returned);
/* Classifies n stamps of one run, in the order the parks returned, into *out. */
void erx_bench_periodic_classify(uint64_t first, uint64_t period,
    const erx_bench_stamp_t *stamps, size_t n, erx_bench_periodic_t *out);

#endif
