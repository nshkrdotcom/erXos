/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "bench_line.h"

/* The line being written; once a write does not fit, full is set and nothing more is. */
typedef struct {
	char *buf;
	size_t size;
	size_t len;
	bool full;
} text_t;

static void
put(text_t *t, const char *s)
{
	for (; *s != '\0' && !t->full; s++) {
		if (t->len + 1 >= t->size)
			t->full = true;
		else
			t->buf[t->len++] = *s;
	}
}

static void
put_u64(text_t *t, uint64_t v)
{
	char digits[21];
	size_t i = sizeof(digits);

	digits[--i] = '\0';
	do {
		digits[--i] = (char)('0' + v % 10);
		v /= 10;
	} while (v != 0);
	put(t, &digits[i]);
}

static void
put_i64(text_t *t, int64_t v)
{
	if (v < 0) {
		put(t, "-");
		/* Negate in unsigned arithmetic: INT64_MIN has no positive int64_t. */
		put_u64(t, (uint64_t)0 - (uint64_t)v);
	} else
		put_u64(t, (uint64_t)v);
}

/* ,"key": before every field but the first. */
static void
key(text_t *t, const char *name)
{
	put(t, ",\"");
	put(t, name);
	put(t, "\":");
}

static void
string(text_t *t, const char *name, const char *value)
{
	key(t, name);
	put(t, "\"");
	put(t, value);
	put(t, "\"");
}

static void
number(text_t *t, const char *name, uint64_t value)
{
	key(t, name);
	put_u64(t, value);
}

/* Every non-empty bucket as [low, last, count], ascending. */
static void
histogram(text_t *t, const char *name, const erx_bench_hist_t *hist)
{
	const char *sep = "";
	uint64_t low, last;

	key(t, name);
	put(t, "[");
	for (unsigned i = 0; i < ERX_BENCH_HIST_BUCKETS; i++) {
		if (hist->count[i] == 0)
			continue;
		erx_bench_hist_bounds(i, &low, &last);
		put(t, sep);
		put(t, "[");
		put_u64(t, low);
		put(t, ",");
		put_u64(t, last);
		put(t, ",");
		put_u64(t, hist->count[i]);
		put(t, "]");
		sep = ",";
	}
	put(t, "]");
}

static void
interval(text_t *t, const char *name, erx_bench_offset_t offset)
{
	key(t, name);
	if (offset.empty) {
		put(t, "null");
		return;
	}
	put(t, "[");
	put_i64(t, offset.low);
	put(t, ",");
	put_i64(t, offset.high);
	put(t, "]");
}

static size_t
finish(text_t *t)
{
	put(t, "}");
	if (t->full)
		return (0);
	t->buf[t->len] = '\0';
	return (t->len);
}

size_t
erx_bench_line_cell(char *buf, size_t size, const erx_bench_cell_t *cell)
{
	text_t t = { buf, size, 0, size == 0 };

	put(&t, "BENCH {\"benchmark\":\"");
	put(&t, cell->benchmark);
	put(&t, "\"");
	string(&t, "operation", cell->operation);
	put(&t, ",\"conditions\":{\"load\":\"");
	put(&t, cell->load);
	put(&t, "\"");
	string(&t, "placement", cell->placement);
	put(&t, ",\"parameters\":{}");
	string(&t, "clock", cell->clock);
	number(&t, "batch", cell->batch);
	put(&t, "}");
	number(&t, "frequency_hz", cell->frequency_hz);
	string(&t, "status", cell->status);
	if (cell->reason != NULL)
		string(&t, "reason", cell->reason);
	number(&t, "samples", cell->hist->samples);
	histogram(&t, "histogram", cell->hist);
	if (cell->hist->samples != 0) {
		number(&t, "min", cell->min);
		number(&t, "max", cell->max);
	}
	key(&t, "largest");
	put(&t, "[");
	for (size_t i = 0; i < cell->nlargest && i < ERX_BENCH_LARGEST; i++) {
		put(&t, i == 0 ? "[" : ",[");
		put_u64(&t, cell->largest[i].sequence);
		put(&t, ",");
		put_u64(&t, cell->largest[i].value);
		put(&t, "]");
	}
	put(&t, "]");
	put(&t, ",\"counts\":{\"lost\":");
	put_u64(&t, cell->lost);
	number(&t, "early", cell->early);
	number(&t, "missed", cell->missed);
	put(&t, "}");
	if (cell->has_uncertainty)
		number(&t, "uncertainty", cell->uncertainty);
	if (cell->periodic != NULL) {
		key(&t, "phases");
		put(&t, "[");
		for (unsigned p = 0; p < ERX_BENCH_PHASES; p++) {
			put(&t, p == 0 ? "[" : ",[");
			put_u64(&t, cell->periodic->phase_min[p]);
			put(&t, ",");
			put_u64(&t, cell->periodic->phase_returns[p]);
			put(&t, "]");
		}
		put(&t, "]");
		histogram(&t, "excess", &cell->periodic->excess);
	}
	return (finish(&t));
}

size_t
erx_bench_line_clock(char *buf, size_t size, const erx_bench_calibration_t *clock)
{
	text_t t = { buf, size, 0, size == 0 };

	put(&t, "CLOCK {\"clock\":\"");
	put(&t, clock->clock);
	put(&t, "\"");
	number(&t, "frequency_hz", clock->frequency_hz);
	number(&t, "increment", clock->increment);
	number(&t, "read_cost", clock->read_cost);
	number(&t, "wait_rounding", clock->wait_rounding);
	key(&t, "pairs");
	put(&t, "[");
	for (size_t i = 0; i < clock->npairs; i++) {
		put(&t, i == 0 ? "{\"cpus\":[" : ",{\"cpus\":[");
		put_u64(&t, clock->pairs[i].cpus[0]);
		put(&t, ",");
		put_u64(&t, clock->pairs[i].cpus[1]);
		put(&t, "]");
		interval(&t, "before", clock->pairs[i].before);
		interval(&t, "after", clock->pairs[i].after);
		put(&t, "}");
	}
	put(&t, "]");
	return (finish(&t));
}
