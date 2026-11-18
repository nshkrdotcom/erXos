/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_ENTROPY_LINE_H
#define ERX_BACKEND_ENTROPY_LINE_H

#include <stddef.h>

#include "erx/core/rng_seed.h"

/*
 * The root's banner line of what seeded its generator (docs/design-fiasco.md, "The
 * call table" and "The Raspberry Pi 4"): a pure function of what went in, so the host
 * test judges every line. It names each source and its length, never its bytes.
 */

/* What the board's random generator gave. The root reads it only when /chosen carried no seed. */
typedef enum erx_board_seed {
	/*
	 * Not read: /chosen carried a seed, the manifest gives the system domain no
	 * generator, or the tree has no enabled generator at its row's path.
	 */
	ERX_BOARD_NONE,
	/* Its ERX_RNG200_SEED_BYTES went in. */
	ERX_BOARD_READ,
	/* It gave fewer words than that within its wait. */
	ERX_BOARD_TIMED_OUT,
	/*
	 * Its node names a malformed window or one other than its row's
	 * (erx_dt_registers), it is stopped with CTRL bits the root cannot write back, or
	 * its bytes could not be mixed.
	 */
	ERX_BOARD_UNREADABLE
} erx_board_seed_t;

/* The longest line, its newline included. */
#define ERX_ENTROPY_LINE_MAX	160

/*
 * Writes the line for the seeds seeded mixed and, when it mixed none, for what board
 * gave; newline-terminated, not NUL-terminated. Returns its bytes.
 */
size_t	erx_entropy_line(char line[ERX_ENTROPY_LINE_MAX], const erx_rng_seeded_t *seeded,
	    erx_board_seed_t board);

#endif /* ERX_BACKEND_ENTROPY_LINE_H */
