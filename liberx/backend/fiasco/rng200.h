/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_RNG200_H
#define ERX_FIASCO_RNG200_H

#include "erx/core/dt.h"
#include "erx/core/rng200.h"
#include "liberx/backend/fiasco/entropy_line.h"

/*
 * The root's read of the board's RNG200 (docs/design-stopgap.md, "The Raspberry Pi
 * 4"), on the stopgap in place of the kernel's platform layer: the device shim around
 * kernel/core/rng200.c, and the only code of the root that touches the generator's
 * registers. It finds the generator by its compatible string in the tree, maps its
 * register page, starts it if it is stopped, and reads ERX_RNG200_SEED_BYTES within
 * ERX_RNG200_WAIT_NS. *read holds the words on ERX_FIASCO_BOARD_READ and is the
 * caller's to erase whatever the answer.
 */
erx_fiasco_board_seed_t	erx_fiasco_rng200_read(const erx_dt_t *tree, erx_rng200_read_t *read);

#endif /* ERX_FIASCO_RNG200_H */
