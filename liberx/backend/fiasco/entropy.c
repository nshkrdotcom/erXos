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
#include "liberx/backend/core/entropy_line.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/entropy.h"
#include "liberx/backend/fiasco/log.h"

/*
 * The generator starts from the counter and from the seeds the firmware's device tree
 * carries in /chosen (erx_rng_seed), or, when it carries none, from what the board's
 * random generator gave (erx_fiasco_rng200_read). The console line names what went in
 * (erx_entropy_line).
 */
static erx_rng_t generator;

void
erx_fiasco_entropy_init(const erx_fiasco_seeds_t *seeds)
{
	const erx_rng_seeded_t seeded = erx_rng_seed(&generator, erx_fiasco_counter(), seeds == NULL ? NULL : &seeds->chosen);
	erx_board_seed_t board = seeds == NULL ? ERX_BOARD_NONE : seeds->board;
	char line[ERX_ENTROPY_LINE_MAX];

	if (board == ERX_BOARD_READ &&
	    !erx_rng_seed_add(&generator, seeds->board_read.data, sizeof(seeds->board_read.data)))
		board = ERX_BOARD_UNREADABLE;
	erx_fiasco_console_write(line, erx_entropy_line(line, &seeded, board));
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
