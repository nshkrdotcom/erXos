/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's file verdicts on the host (liberx/backend/fiasco/verdict.c), over an
 * archive the test writes: an image entry's file is hashed by its first check alone,
 * which every later check and read of its verdict answers from, a damaged file is
 * refused and stays refused, and an index past the archive is refused before the
 * table is read. Each failure prints what broke and exits 1.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "blake3/blake3.h"
#include "erx/abi.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/verdict.h"
#include "tools/host/input.h"

/* Large for a stack: one table for the sound archive and one for it damaged. */
static erx_fiasco_verdicts_t first_verdicts, damaged_verdicts;
static erx_pack_scratch_t scratch;
static erx_blake3_ctx_t hasher;

static bool
expect(bool holds, const char *what)
{
	if (!holds)
		printf("verdict: %s\n", what);
	return (holds);
}

int
main(int argc, char **argv)
{
	erx_pack_error_t error;
	erx_pack_entry_t image;
	erx_pack_view_t view;
	uint8_t *bytes;
	size_t length;
	uint32_t index;
	bool held = true;

	if (argc != 2) {
		fputs("usage: fiasco-verdict ARCHIVE\n", stderr);
		return (2);
	}
	bytes = erx_host_input_read(argv[1], &length);
	if (bytes == NULL || !erx_pack_open(bytes, length, &scratch, &hasher, &view, &error)) {
		puts("verdict: the archive does not open");
		free(bytes);
		return (1);
	}
	index = view.header.root_entry;
	if (!erx_pack_entry_at(&view, index, &image) || image.kind != ERX_ENTRY_IMAGE || image.data_size == 0) {
		puts("verdict: the archive's root entry is no image");
		free(bytes);
		return (1);
	}

	held &= expect(!erx_fiasco_verdict_good(&first_verdicts, index), "an unchecked file reads good");
	held &= expect(erx_fiasco_verdict_check(&first_verdicts, &view, index, &hasher) == ERX_OK, "a sound file is refused");
	held &= expect(erx_fiasco_verdict_good(&first_verdicts, index), "a checked file reads unchecked");
	held &= expect(!erx_fiasco_verdict_good(&first_verdicts, index + 1), "a check marks another file");

	/*
	 * The file's bytes change after its check, which nothing in the root can do to the
	 * archive's read-only pages: a second check that hashed again would refuse it.
	 */
	bytes[image.data_off] ^= 0xffu;
	held &= expect(erx_fiasco_verdict_check(&first_verdicts, &view, index, &hasher) == ERX_OK,
	    "a checked file was hashed twice");

	held &= expect(erx_fiasco_verdict_check(&damaged_verdicts, &view, index, &hasher) == ERX_ECORRUPT,
	    "a damaged file is not refused as damaged");
	held &= expect(!erx_fiasco_verdict_good(&damaged_verdicts, index), "a refused file reads good");
	/* Mended, the file would pass a check that hashed it again: a refusal is final. */
	bytes[image.data_off] ^= 0xffu;
	held &= expect(erx_fiasco_verdict_check(&damaged_verdicts, &view, index, &hasher) == ERX_ECORRUPT,
	    "a refused file was hashed again");

	held &= expect(erx_fiasco_verdict_check(&first_verdicts, &view, view.header.nentries, &hasher) == ERX_ERANGE,
	    "an index past the archive is checked");
	held &= expect(erx_fiasco_verdict_check(&first_verdicts, &view, UINT32_MAX, &hasher) == ERX_ERANGE,
	    "an index past the table is checked");
	held &= expect(!erx_fiasco_verdict_good(&first_verdicts, UINT32_MAX), "an index past the table reads good");

	free(bytes);
	if (held)
		puts("verdict: ok");
	return (held ? 0 : 1);
}
