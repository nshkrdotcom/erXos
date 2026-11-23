/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BCM2711_PINS_H
#define ERX_CORE_BCM2711_PINS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The functions of the BCM2711's on-board pins, which the root sets once at boot, before
 * any domain starts (docs/design-header-io.md, "On-board pins"): the manifest's
 * onboard_pins rows, each a pin and the alternate number of its function, written into
 * the six function-select registers GPFSEL0 to GPFSEL5. This is the pure part: the new
 * register words, from the words as read. The caller's device shim reads the registers,
 * writes the words that change and reads them back. The register facts are
 * hw/svd/bcm2711_gpio/bcm2711_gpio.svd's.
 *
 * Only pins of banks 1 and 2, GPIO 28 to 57, can be set. Bank 0, GPIO 0 to 27, holds every
 * header pin, the console's and the host link's among them, whose functions config.txt
 * sets and whose plain GPIO the pin controller's driver serves at run time; no row of the
 * manifest reaches them through this core.
 */

/* The device tree's compatible string of the pin controller, which the platform row names. */
#define ERX_BCM2711_PINS_COMPATIBLE	"brcm,bcm2711-gpio"
/* GPFSEL0 to GPFSEL5. */
#define ERX_BCM2711_PINS_REGISTERS	6u
/* The most rows a plan takes: one for each pin of banks 1 and 2. */
#define ERX_BCM2711_PINS_ROWS_MAX	30u

/* The function-select words, GPFSEL0's first. */
typedef struct erx_bcm2711_fsel {
	uint32_t	word[ERX_BCM2711_PINS_REGISTERS];
} erx_bcm2711_fsel_t;

/*
 * Sets each of the count rows' functions in *fsel, the words as read, and leaves every other
 * field as it was; a later row of one pin wins. A word the rows change keeps only its fields,
 * so its reserved bits are clear and its generated write takes it; a word they leave as read
 * is left whole. Returns false, with *fsel unchanged, when a row names a pin outside banks 1
 * and 2 or an alternate past 5, or count is past ERX_BCM2711_PINS_ROWS_MAX: the plan is taken
 * whole or not at all.
 */
bool	erx_bcm2711_pins_plan(const erx_mf_onboard_pin_t *rows, size_t count, erx_bcm2711_fsel_t *fsel);

#endif /* ERX_CORE_BCM2711_PINS_H */
