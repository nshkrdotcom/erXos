/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/core/dt.h"
#include "erx/core/rng200.h"
#include "erx/core/rng_seed.h"
#include "liberx/backend/fiasco/entropy_line.h"

/*
 * Neither accelerator has the random-number instruction, so a boot that mixed no seed
 * starts from the counter alone, and anyone who can guess its timing can guess every
 * byte: that line says so, and why when the board's generator failed. The other lines
 * name each source that went in and its length. None judges a source, so the machine
 * page's entropy quality stays unreported.
 */
#define LINE_COUNTER	"erx: entropy: quality: low, from the counter alone"
#define LINE_FROM	"erx: entropy: from "
#define LINE_BOARD	"the RNG200"
#define LINE_LAST	" bytes) and the counter\n"

_Static_assert(ERX_RNG200_WAIT_NS == UINT64_C(100000000), "the timed-out line says 100 ms");
_Static_assert(ERX_DT_SEED_MAX <= 9999 && ERX_RNG200_SEED_BYTES <= 9999, "a length is at most four digits");

static size_t	line_append(char *, size_t, const char *);
static size_t	line_append_decimal(char *, size_t, size_t);
static size_t	line_board(char *, erx_fiasco_board_seed_t);

size_t
erx_fiasco_entropy_line(char line[ERX_FIASCO_ENTROPY_LINE_MAX], const erx_rng_seeded_t *seeded,
    erx_fiasco_board_seed_t board)
{
	static const char *const names[ERX_DT_SEEDS] = ERX_DT_SEED_NAMES;
	size_t used, left = 0;

	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++)
		left += seeded->length[seed] != 0;
	if (left == 0)
		return (line_board(line, board));
	used = line_append(line, 0, LINE_FROM);
	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++) {
		if (seeded->length[seed] == 0)
			continue;
		used = line_append(line, used, "/chosen/");
		used = line_append(line, used, names[seed]);
		used = line_append(line, used, " (");
		used = line_append_decimal(line, used, seeded->length[seed]);
		left--;
		used = line_append(line, used, left == 0 ? LINE_LAST : " bytes), ");
	}
	return (used);
}

/* The line of a boot that mixed no seed of /chosen. */
static size_t
line_board(char *line, erx_fiasco_board_seed_t board)
{
	size_t used;

	switch (board) {
	case ERX_FIASCO_BOARD_READ:
		used = line_append(line, 0, LINE_FROM LINE_BOARD " (");
		used = line_append_decimal(line, used, ERX_RNG200_SEED_BYTES);
		return (line_append(line, used, LINE_LAST));
	case ERX_FIASCO_BOARD_TIMED_OUT:
		return (line_append(line, 0, LINE_COUNTER ", since " LINE_BOARD " gave too few words within 100 ms\n"));
	case ERX_FIASCO_BOARD_UNREADABLE:
		return (line_append(line, 0, LINE_COUNTER ", since " LINE_BOARD " could not be read\n"));
	case ERX_FIASCO_BOARD_NONE:
		break;
	}
	return (line_append(line, 0, LINE_COUNTER "\n"));
}

/* Appends text to the line's used bytes, as much as fits, and returns the bytes used. */
static size_t
line_append(char *line, size_t used, const char *text)
{
	while (*text != '\0' && used < ERX_FIASCO_ENTROPY_LINE_MAX)
		line[used++] = *text++;
	return (used);
}

static size_t
line_append_decimal(char *line, size_t used, size_t value)
{
	char digits[4];
	size_t count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0 && count < sizeof(digits));
	while (count > 0 && used < ERX_FIASCO_ENTROPY_LINE_MAX)
		line[used++] = digits[--count];
	return (used);
}
