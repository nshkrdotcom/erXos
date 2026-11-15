/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/rng200.c and liberx/backend/fiasco/entropy_line.c for
 * test/host/rng200_test.rb. Each line of standard input is one request and gets one
 * line of answer:
 *
 *   start NOW               -> start DEADLINE
 *   next COUNT NOW          -> next poll|take|done|timed_out TAKE
 *   take WORD               -> take WORDS
 *   line RNG KASLR BOARD    -> the banner line, without its newline, for seeds of RNG and
 *                              KASLR bytes and BOARD none|read|timed_out|unreadable
 *
 * The read is one value across requests, as the shim keeps it.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/rng200.h"
#include "liberx/backend/fiasco/entropy_line.h"

static const char *const actions[] = { "poll", "take", "done", "timed_out" };
static const char *const boards[] = { "none", "read", "timed_out", "unreadable" };

static int
board_of(const char *name)
{
	for (size_t board = 0; board < sizeof(boards) / sizeof(boards[0]); board++)
		if (strcmp(name, boards[board]) == 0)
			return ((int)board);
	return (-1);
}

int
main(void)
{
	char request[256], word[16], line[ERX_FIASCO_ENTROPY_LINE_MAX];
	unsigned long long a, b;
	erx_rng200_read_t read = { 0 };
	erx_rng_seeded_t seeded;
	uint32_t take;
	size_t length;
	int board;

	while (fgets(request, sizeof(request), stdin) != NULL) {
		if (sscanf(request, "start %llu", &a) == 1) {
			read = erx_rng200_start(a);
			printf("start %" PRIu64 "\n", read.deadline_ns);
		} else if (sscanf(request, "next %llu %llu", &a, &b) == 2) {
			const erx_rng200_action_t action = erx_rng200_next(&read, (uint32_t)a, b, &take);

			printf("next %s %" PRIu32 "\n", actions[action], take);
		} else if (sscanf(request, "take %llu", &a) == 1) {
			erx_rng200_take(&read, (uint32_t)a);
			printf("take %" PRIu32 "\n", read.words);
		} else if (sscanf(request, "line %llu %llu %15s", &a, &b, word) == 3 && (board = board_of(word)) >= 0) {
			seeded.length[ERX_DT_SEED_RNG] = (size_t)a;
			seeded.length[ERX_DT_SEED_KASLR] = (size_t)b;
			length = erx_fiasco_entropy_line(line, &seeded, (erx_fiasco_board_seed_t)board);
			if (length == 0 || length > sizeof(line) || line[length - 1] != '\n')
				return (3);
			printf("line %.*s\n", (int)(length - 1), line);
		} else {
			return (2);
		}
	}
	return (0);
}
