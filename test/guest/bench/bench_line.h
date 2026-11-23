/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The guests' BENCH and CLOCK lines (docs/design-bench.md, "A benchmark"): each formats
 * one line, prefix and JSON object without a newline, into a caller's buffer, and fails
 * whole when the line does not fit, so a cut line is never printed. The host's
 * Erx::BenchMeasurement is the lines' one validator; the strings given here are the
 * guest's own constants, written as they are.
 */

#ifndef ERX_BENCH_LINE_H
#define ERX_BENCH_LINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bench_clock.h"
#include "bench_hist.h"
#include "bench_periodic.h"

#define	ERX_BENCH_LARGEST	16

/* A sample and its sequence number in the run. */
typedef struct {
	uint64_t sequence;
	uint64_t value;
} erx_bench_sample_t;

/* One cell. reason is NULL exactly when status is "measured". */
typedef struct {
	const char *benchmark;
	const char *operation;
	const char *load;
	const char *placement;
	const char *clock;
	uint64_t batch;
	uint64_t frequency_hz;
	const char *status;
	const char *reason;
	const erx_bench_hist_t *hist;
	uint64_t min;
	uint64_t max;
	/* At most ERX_BENCH_LARGEST samples, the largest first. */
	const erx_bench_sample_t *largest;
	size_t nlargest;
	uint64_t lost;
	uint64_t early;
	uint64_t missed;
	/* A one-way cell across CPUs: the half-width of its pair's offset hull. */
	bool has_uncertainty;
	uint64_t uncertainty;
	/* A periodic cell's classification, whose late histogram is hist; NULL otherwise. */
	const erx_bench_periodic_t *periodic;
} erx_bench_cell_t;

/* One pair of CPUs a cell was stamped across, and its offset before and after the cells. */
typedef struct {
	unsigned cpus[2];
	erx_bench_offset_t before;
	erx_bench_offset_t after;
} erx_bench_pair_t;

typedef struct {
	const char *clock;
	uint64_t frequency_hz;
	uint64_t increment;
	uint64_t read_cost;
	uint64_t wait_rounding;
	const erx_bench_pair_t *pairs;
	size_t npairs;
} erx_bench_calibration_t;

/* Each writes its line into buf, NUL-terminated, and returns its length, or 0 if it does
 * not fit in size bytes. */
size_t erx_bench_line_cell(char *buf, size_t size, const erx_bench_cell_t *cell);
size_t erx_bench_line_clock(char *buf, size_t size, const erx_bench_calibration_t *clock);

#endif
