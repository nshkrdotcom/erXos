/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ENTROPY_H
#define ERX_FIASCO_ENTROPY_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/dt.h"
#include "erx/core/rng200.h"
#include "liberx/backend/fiasco/entropy_line.h"

/*
 * The entropy calls' bodies (docs/design-stopgap.md, "The call table"): the kernel's
 * generator, kernel/core/rng.c, in the root. The service alone runs the bodies, and the
 * root's first thread the init before the service runs, so nothing here takes a lock.
 */

/*
 * What seeds the generator besides the counter, as the program's tree read gives it
 * (erx_fiasco_program_tree): /chosen's seeds and, when /chosen carries neither, what
 * the board's random generator gave, its words in board_read on ERX_FIASCO_BOARD_READ.
 * The bytes are secret; whoever holds the record erases it.
 */
typedef struct erx_fiasco_seeds {
	erx_dt_seeds_t		 chosen;
	erx_fiasco_board_seed_t	 board;
	erx_rng200_read_t	 board_read;
} erx_fiasco_seeds_t;

/*
 * Seeds the generator from the counter and seeds, or NULL (erx_rng_seed, then
 * erx_rng_seed_add for the board's words), and says on the console what went in.
 */
void	erx_fiasco_entropy_init(const erx_fiasco_seeds_t *seeds);
/* The next two words of output. */
int	erx_fiasco_entropy_read_body(uint64_t *first, uint64_t *second);
/* Mixes in the request's bytes. More than its four words hold is ERX_EINVAL. */
int	erx_fiasco_entropy_add_body(const erx_fiasco_entropy_add_request_t *request);

#endif /* ERX_FIASCO_ENTROPY_H */
