/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_BCM2711_PINS_H
#define ERX_FIASCO_BCM2711_PINS_H

#include <stddef.h>

#include "erx/abi.h"
#include "erx/core/dt.h"
#include "erx/mmio.h"

/*
 * The on-board pins on Fiasco (docs/design-header-io.md, "On-board pins";
 * docs/design-fiasco.md, "The Raspberry Pi 4"), which the root sets once at boot, before
 * any domain starts: the device shim around kernel/core/bcm2711_pins.c, and the only code
 * of the root that touches the pin controller's registers. No runtime holds its window:
 * its unit is of no kind.
 */

/* What the root did with the manifest's on-board pins (erx_fiasco_program_board). */
typedef enum erx_fiasco_board_pins {
	/* The manifest has no pins row the root sets: nothing to set, and no line. */
	ERX_FIASCO_BOARD_PINS_NONE = 1,
	/* The manifest gives the system domain no pin controller: nothing is written. */
	ERX_FIASCO_BOARD_PINS_ABSENT,
	/* The tree does not confirm the controller's row: nothing is written. */
	ERX_FIASCO_BOARD_PINS_UNCONFIRMED,
	/* The rows, the page or the registers' reach are refused: nothing is written. */
	ERX_FIASCO_BOARD_PINS_REFUSED,
	/* The changed words are written, but some word reads back otherwise. */
	ERX_FIASCO_BOARD_PINS_MISMATCH,
	/* Every row's function is set and all six words read back as planned. */
	ERX_FIASCO_BOARD_PINS_SET
} erx_fiasco_board_pins_t;

/*
 * Reads GPFSEL0 to GPFSEL5 through device, writes each word the plan of the count rows
 * changes and reads all six back. SET when every word reads back as planned; REFUSED,
 * having written nothing, when a register lies past device or the plan is refused;
 * MISMATCH when, after the writes, a word reads back otherwise.
 */
erx_fiasco_board_pins_t	erx_fiasco_bcm2711_pins_apply(erx_mmio_t device, const erx_mf_pin_t *rows,
			    size_t count);

/*
 * Maps the first page of window, which the tree has confirmed, and applies the rows through
 * it (erx_fiasco_bcm2711_pins_apply); REFUSED, having written nothing, when the page cannot
 * be mapped.
 */
erx_fiasco_board_pins_t	erx_fiasco_bcm2711_pins_set(erx_dt_window_t window, const erx_mf_pin_t *rows,
			    size_t count);

#endif /* ERX_FIASCO_BCM2711_PINS_H */
