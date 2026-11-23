/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs test/host/bench_periodic_test.rb's cases against test/guest/bench's histogram and
 * periodic cores, printing "NAME ok" or "NAME bad" for each, in a fixed order.
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "bench_clock.h"
#include "bench_hist.h"
#include "bench_line.h"
#include "bench_periodic.h"

#define	RUN_MAX	512

static erx_bench_stamp_t stamps[RUN_MAX];
static erx_bench_periodic_t result;

/* A sample over twenty octaves lands in a bucket that holds it and is at most 1/64 wide. */
static bool
hist_case(void)
{
	uint64_t low, last, value;

	for (unsigned octave = 0; octave < 20; octave++) {
		for (uint64_t step = 0; step < 7; step++) {
			value = (UINT64_C(1) << octave) + ((UINT64_C(1) << octave) - 1) * step / 6;
			erx_bench_hist_bounds(erx_bench_hist_index(value), &low, &last);
			if (value < low || value > last)
				return (false);
			if (value >= ERX_BENCH_HIST_SUB && (last - low + 1) * ERX_BENCH_HIST_SUB > low)
				return (false);
		}
	}
	return (true);
}

/*
 * Parks of count deadlines of period from first under a timer: each returns at its
 * deadline rounded up to a multiple of tick (1 for none), plus cost, plus extra at the
 * park of index late_k. Returns the number of stamps.
 */
static size_t
simulate(uint64_t first, uint64_t period, uint32_t count, uint64_t tick, uint64_t cost,
    uint32_t late_k, uint64_t extra)
{
	uint64_t deadline, returned;
	uint32_t k;
	size_t n;

	n = 0;
	for (k = 0; k < count && n < RUN_MAX; k = erx_bench_periodic_next(first, period, k, returned)) {
		deadline = erx_bench_periodic_deadline(first, period, k);
		returned = (deadline + tick - 1) / tick * tick + cost + (k == late_k ? extra : 0);
		stamps[n++] = (erx_bench_stamp_t){ .k = k, .returned = returned };
	}
	erx_bench_periodic_classify(first, period, stamps, n, &result);
	return (n);
}

/* A 5 ms stall at a 100 us period is at least four missed periods and 5 ms late. */
static bool
stall_case(void)
{
	simulate(1000, 100, 200, 1, 1, 20, 5000);
	return (result.missed >= 4 && result.max_late >= 5000 && result.early == 0);
}

/* A return 10 ticks before its deadline is early; one at its deadline is not. */
static bool
early_case(void)
{
	const uint64_t first = 1000, period = 160;

	stamps[0] = (erx_bench_stamp_t){ 0, erx_bench_periodic_deadline(first, period, 0) - 10 };
	stamps[1] = (erx_bench_stamp_t){ 1, erx_bench_periodic_deadline(first, period, 1) };
	stamps[2] = (erx_bench_stamp_t){ 2, erx_bench_periodic_deadline(first, period, 2) + 3 };
	erx_bench_periodic_classify(first, period, stamps, 3, &result);
	return (result.early == 1 && result.returns == 3 && result.missed == 0);
}

/* 160 deadlines put ten in each of the sixteen phases of a period. */
static bool
sweep_case(void)
{
	const uint64_t first = 5, period = 1600;
	uint32_t seen[ERX_BENCH_PHASES] = { 0 };
	uint64_t offset;

	for (uint32_t k = 0; k < 160; k++) {
		offset = erx_bench_periodic_deadline(first, period, k) - first - (uint64_t)k * period;
		if (offset % (period / ERX_BENCH_PHASES) != 0 || offset >= period)
			return (false);
		seen[offset / (period / ERX_BENCH_PHASES)]++;
	}
	for (unsigned phase = 0; phase < ERX_BENCH_PHASES; phase++)
		if (seen[phase] != 10)
			return (false);
	return (true);
}

/*
 * A timer that fires only on ticks of one period: each phase's minimum lateness differs
 * by most of a tick across the phases, and each return's excess above its phase's minimum
 * is reported, a 7-tick jitter among them.
 */
static bool
tick_case(void)
{
	const uint64_t tick = 1600;
	uint64_t least, most;
	size_t n;

	n = simulate(16037, tick, 160, tick, 5, 50, 7);
	least = UINT64_MAX;
	most = 0;
	for (unsigned phase = 0; phase < ERX_BENCH_PHASES; phase++) {
		if (result.phase_returns[phase] == 0)
			return (false);
		least = result.phase_min[phase] < least ? result.phase_min[phase] : least;
		most = result.phase_min[phase] > most ? result.phase_min[phase] : most;
	}
	return (most - least >= tick * 14 / 16 && result.excess.samples == n &&
	    result.excess.count[erx_bench_hist_index(7)] == 1 && result.excess.count[0] == n - 1);
}

/*
 * Rounds with B's counter offset by true_offset from A's and every transfer taking
 * transfer ticks, A's first stamp at start.
 */
static erx_bench_offset_t
calibrate(int64_t true_offset, uint64_t transfer, uint64_t start)
{
	static erx_bench_round_t rounds[1000];

	for (size_t i = 0; i < sizeof(rounds) / sizeof(rounds[0]); i++) {
		uint64_t a = start + i * 1000;

		rounds[i] = (erx_bench_round_t){ .a = a,
		    .b = (uint64_t)((int64_t)(a + transfer) + true_offset), .c = a + 2 * transfer };
	}
	return (erx_bench_offset(rounds, sizeof(rounds) / sizeof(rounds[0]), 1));
}

/* A 50-tick offset inside 100-tick transfers, widened by one tick: [-51, 151]. */
static bool
offset_case(void)
{
	erx_bench_offset_t offset = calibrate(50, 100, 1000000);

	return (!offset.empty && offset.low == -51 && offset.high == 151 &&
	    erx_bench_offset_half_width(offset) == 101);
}

/* Half-width 101: a median of 1,010 ticks is accepted, 1,009 refused. */
static bool
cell_case(void)
{
	erx_bench_offset_t offset = calibrate(50, 100, 1000000);

	return (erx_bench_cell_bounded(true, offset, offset, 1010) &&
	    !erx_bench_cell_bounded(true, offset, offset, 1009) &&
	    erx_bench_cell_bounded(false, offset, offset, 1));
}

static const erx_bench_round_t before_rounds_none[1];

/* An offset that moves by 300 ticks between the calibrations refuses the cells. */
static bool
drift_case(void)
{
	erx_bench_offset_t before = calibrate(50, 100, 1000000);
	erx_bench_offset_t after = calibrate(350, 100, 5000000);

	erx_bench_offset_t moved = calibrate(200, 100, 5000000);

	/* A 150-tick move that still overlaps is bounded by the hull, half-width 176. */
	return (!after.empty && !erx_bench_cell_bounded(true, before, after, UINT64_MAX / 16) &&
	    !erx_bench_cell_bounded(true, before, moved, 1759) &&
	    erx_bench_cell_bounded(true, before, moved, 1760) &&
	    erx_bench_offset(before_rounds_none, 0, 1).empty);
}

/*
 * Prints a fast cell, a periodic cell and a two-CPU calibration as the guests print them,
 * for the host's validator to read (test/host/bench_guest_lines_test.rb).
 */
static void
print_lines(void)
{
	static erx_bench_hist_t fast;
	static erx_bench_stamp_t stamps[32];
	static erx_bench_periodic_t periodic;
	static char line[64 << 10];
	erx_bench_sample_t largest[] = { { 7, 1199 }, { 3, 1100 } };
	erx_bench_pair_t pairs[] = {
		{ { 0, 1 }, { -40, 12, false }, { -35, 15, false } },
		{ { 0, 2 }, { 0, 0, true }, { INT64_MIN, INT64_MAX, false } },
	};

	for (uint64_t i = 0; i < 40; i++)
		erx_bench_hist_add(&fast, i == 7 ? 1199 : i == 3 ? 1100 : 1000 + i);
	erx_bench_cell_t cell = { .benchmark = "wake", .operation = "wake-same-cpu", .load = "idle",
		.placement = "same-cpu", .clock = "counter", .batch = 1, .frequency_hz = 24000000,
		.status = "measured", .hist = &fast, .min = 1000, .max = 1199, .largest = largest,
		.nlargest = 2 };
	if (erx_bench_line_cell(line, sizeof(line), &cell) != 0)
		printf("%s\n", line);

	for (uint32_t k = 0; k < 32; k++)
		stamps[k] = (erx_bench_stamp_t){ k, erx_bench_periodic_deadline(1000, 1000, k) + 5 + k % 3 };
	erx_bench_periodic_classify(1000, 1000, stamps, 32, &periodic);
	cell = (erx_bench_cell_t){ .benchmark = "wake", .operation = "park-deadline", .load = "idle",
		.placement = "service-cpu", .clock = "counter", .batch = 1, .frequency_hz = 24000000,
		.status = "partial", .reason = "cut short", .hist = &periodic.late, .min = 5, .max = 7,
		.largest = (erx_bench_sample_t[]){ { 2, 7 } }, .nlargest = 1, .periodic = &periodic };
	if (erx_bench_line_cell(line, sizeof(line), &cell) != 0)
		printf("%s\n", line);

	erx_bench_calibration_t clock = { "counter", 24000000, 1, 2, 24, pairs, 2 };
	if (erx_bench_line_clock(line, sizeof(line), &clock) != 0)
		printf("%s\n", line);
	/* A line that does not fit is not written. */
	printf("short %s\n", erx_bench_line_clock(line, 40, &clock) == 0 ? "refused" : "written");
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "lines") == 0) {
		print_lines();
		return (0);
	}
	static const struct {
		const char *name;
		bool (*run)(void);
	} cases[] = {
		{ "hist", hist_case }, { "stall", stall_case }, { "early", early_case },
		{ "sweep", sweep_case }, { "tick", tick_case }, { "offset", offset_case },
		{ "cell", cell_case }, { "drift", drift_case },
	};

	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
		printf("%s %s\n", cases[i].name, cases[i].run() ? "ok" : "bad");
	return (0);
}
