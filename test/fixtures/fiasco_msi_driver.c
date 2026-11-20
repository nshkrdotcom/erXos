/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives liberx/backend/fiasco/msi_lines.c on the host over QEMU virt's frame, interrupt
 * ids 80 to 143: every line from the first to the last, then ERX_ELIMIT; a freed line
 * taken again; a platform without a frame refused. Prints "msi_lines: N" with the count
 * of checks, or names the first that failed and exits 1.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/msi_lines.h"

#define FIRST	80u
#define COUNT	64u

/* The lines taken, by offset from FIRST; a line past the range lands in its own slot. */
typedef struct taken {
	bool	held[COUNT + 1];
} taken_t;

static int checks;

static void
expect(bool ok, const char *what)
{
	if (!ok) {
		printf("msi_lines: %s\n", what);
		exit(1);
	}
	checks++;
}

static bool
held(uint32_t line, const void *context)
{
	const taken_t *const taken = context;

	return (line >= FIRST && line - FIRST <= COUNT && taken->held[line - FIRST]);
}

int
main(void)
{
	const erx_fiasco_msi_range_t range = { .first = FIRST, .count = COUNT };
	taken_t taken = { 0 };
	uint32_t line;

	for (uint32_t offset = 0; offset < COUNT; offset++) {
		expect(erx_fiasco_msi_line_take(range, held, &taken, &line) == ERX_OK, "a free line was refused");
		expect(line == FIRST + offset, "the line taken was not the lowest free one");
		taken.held[line - FIRST] = true;
	}
	expect(erx_fiasco_msi_line_take(range, held, &taken, &line) == ERX_ELIMIT, "a line past the range's end was taken");
	taken.held[17] = false;
	expect(erx_fiasco_msi_line_take(range, held, &taken, &line) == ERX_OK && line == FIRST + 17,
	    "a freed line was not taken again");
	expect(erx_fiasco_msi_line_take((erx_fiasco_msi_range_t){ .first = FIRST, .count = 0 }, held, &taken, &line) ==
	    ERX_ENOTSUP, "a platform without a frame gave a line");
	printf("msi_lines: %d\n", checks);
	return (0);
}
