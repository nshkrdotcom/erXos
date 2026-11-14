/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/rng.h"
#include "erx/core/rng_seed.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/entropy.h"
#include "liberx/backend/fiasco/log.h"

/*
 * The generator starts from the counter and from the seeds the firmware's device tree
 * carries in /chosen (erx_rng_seed). Neither accelerator has the random-number
 * instruction, so a boot whose tree carries no seed starts from the counter alone, and
 * anyone who can guess its timing can guess every byte: the first line says so. The
 * other names each seed that went in and its length, never its bytes. Neither judges a
 * firmware's seed, so the machine page's entropy quality stays unreported.
 */
#define ENTROPY_COUNTER_LINE	"erx: entropy: quality: low, from the counter alone\n"
#define ENTROPY_SEEDED_LINE	"erx: entropy: from "
/* The seeded line: its words, each seed's name and its length of at most four digits. */
#define ENTROPY_LINE_MAX	160
_Static_assert(ERX_DT_SEED_MAX <= 9999, "a seed's length is at most four digits");

static erx_rng_t generator;

static size_t	entropy_append(char *, size_t, const char *);
static size_t	entropy_append_decimal(char *, size_t, size_t);

void
erx_fiasco_entropy_init(const erx_dt_seeds_t *seeds)
{
	static const char *const names[ERX_DT_SEEDS] = ERX_DT_SEED_NAMES;
	const erx_rng_seeded_t seeded = erx_rng_seed(&generator, erx_fiasco_counter(), seeds);
	char line[ENTROPY_LINE_MAX];
	size_t used, left = 0;
	bool last;

	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++)
		left += seeded.length[seed] != 0;
	if (left == 0) {
		erx_fiasco_console_write(ENTROPY_COUNTER_LINE, sizeof(ENTROPY_COUNTER_LINE) - 1);
		return;
	}
	used = entropy_append(line, 0, ENTROPY_SEEDED_LINE);
	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++) {
		if (seeded.length[seed] == 0)
			continue;
		used = entropy_append(line, used, "/chosen/");
		used = entropy_append(line, used, names[seed]);
		used = entropy_append(line, used, " (");
		used = entropy_append_decimal(line, used, seeded.length[seed]);
		left--;
		last = left == 0;
		used = entropy_append(line, used, last ? " bytes) and the counter\n" : " bytes), ");
	}
	erx_fiasco_console_write(line, used);
}

/* Appends text to the line's used bytes, as much as fits, and returns the bytes used. */
static size_t
entropy_append(char *line, size_t used, const char *text)
{
	while (*text != '\0' && used < ENTROPY_LINE_MAX)
		line[used++] = *text++;
	return (used);
}

static size_t
entropy_append_decimal(char *line, size_t used, size_t value)
{
	char digits[4];
	size_t count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0 && count < sizeof(digits));
	while (count > 0 && used < ENTROPY_LINE_MAX)
		line[used++] = digits[--count];
	return (used);
}

int
erx_fiasco_entropy_read_body(uint64_t *first, uint64_t *second)
{
	uint64_t words[2];

	if (!erx_rng_read(&generator, (uint8_t *)words, sizeof(words)))
		return (ERX_ENOTSUP);
	*first = words[0];
	*second = words[1];
	return (ERX_OK);
}

int
erx_fiasco_entropy_add_body(const erx_fiasco_entropy_add_request_t *request)
{
	const uint64_t words[] = { request->word0, request->word1, request->word2, request->word3 };
	erx_rng_digest_t digest;

	if (request->len > sizeof(words))
		return (ERX_EINVAL);
	if (!erx_rng_digest(&digest, words, (size_t)request->len) || !erx_rng_mix(&generator, &digest))
		return (ERX_ENOTSUP);
	return (ERX_OK);
}
