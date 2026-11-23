/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The cross-CPU offset of the guests' calibration (docs/design-bench.md, "The one
 * clock"). Thread A stamps a and passes a token to thread B on another CPU, which stamps b
 * and passes it back; A stamps c. Causality bounds B's counter less A's in every round,
 * b - c <= offset <= b - a, whatever the transfers took, so the offset lies in the
 * intersection of the rounds' intervals, each widened by the smallest increment two reads
 * observe. An empty intersection means the stamps contradict each other.
 */

#ifndef ERX_BENCH_CLOCK_H
#define ERX_BENCH_CLOCK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bench_hist.h"

/* Two back-to-back reads of the counter on one CPU. */
typedef struct {
	uint64_t first;
	uint64_t second;
} erx_bench_reads_t;

/*
 * What back-to-back reads show (docs/design-bench.md, "The one clock"): the smallest
 * increment a pair observed, 0 where no pair moved, and the median cost of a read.
 */
typedef struct {
	uint64_t increment;
	uint64_t read_cost;
} erx_bench_read_cal_t;

/* Fills n pairs, each two calls of read with nothing between them. */
void erx_bench_read_pairs(uint64_t (*read)(void), erx_bench_reads_t *pairs, size_t n);
/* The calibration of n pairs; deltas is the caller's histogram, cleared and filled here. */
erx_bench_read_cal_t erx_bench_read_calibration(const erx_bench_reads_t *pairs, size_t n,
    erx_bench_hist_t *deltas);

/* One round's stamps: a and c on A's counter, b on B's. Each is below 2^63. */
typedef struct {
	uint64_t a;
	uint64_t b;
	uint64_t c;
} erx_bench_round_t;

/* B's counter less A's lies in [low, high]; empty when no offset fits every round. */
typedef struct {
	int64_t low;
	int64_t high;
	bool empty;
} erx_bench_offset_t;

/* The interval of n rounds, widened by increment ticks at each end; empty for none. */
erx_bench_offset_t erx_bench_offset(const erx_bench_round_t *rounds, size_t n,
    uint64_t increment);
/*
 * Why a cell is unsupported, or NULL where it may report (docs/design-bench.md, "The one
 * clock"): one whose stamps are read on one CPU always may; one whose stamps are read on
 * two needs the pair's calibrations before and after its run to be non-empty and to
 * overlap, and the half-width of their hull, which holds the offset however it moved
 * between them, to be at most a tenth of the cell's median.
 */
const char *erx_bench_cell_unsupported(bool two_cpus, erx_bench_offset_t before,
    erx_bench_offset_t after, uint64_t median);
/* The half-width of a non-empty interval, rounded up: a one-way cell's uncertainty. */
uint64_t erx_bench_offset_half_width(erx_bench_offset_t offset);

#endif
