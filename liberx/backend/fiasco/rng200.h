/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_RNG200_H
#define ERX_FIASCO_RNG200_H

#include "erx/core/dt.h"
#include "erx/core/rng200.h"
#include "liberx/backend/core/entropy_line.h"

/*
 * The root's read of the board's RNG200 (docs/design-fiasco.md, "The Raspberry Pi
 * 4"), on Fiasco in place of the kernel's platform layer: the device shim around
 * kernel/core/rng200.c, and the only code of the root that touches the generator's
 * registers. window and path are the generator's row in the platform record, as the
 * manifest carries it; the root maps the window only when the tree's enabled node at path
 * names exactly it (erx_dt_registers), so a tree cannot move the read onto another
 * device's page. It maps the register page, starts the generator if it is stopped, and
 * reads ERX_RNG200_SEED_BYTES within ERX_RNG200_WAIT_NS. *read holds the words on
 * ERX_BOARD_READ and is the caller's to erase whatever the answer.
 */
erx_board_seed_t	erx_fiasco_rng200_read(const erx_dt_t *tree, const char *path, erx_dt_window_t window,
			    erx_rng200_read_t *read);

#endif /* ERX_FIASCO_RNG200_H */
