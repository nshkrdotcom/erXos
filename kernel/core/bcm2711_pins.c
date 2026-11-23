/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/bcm2711_pins.h"
#include "erx/hw/bcm2711_gpio.h"

#define nitems(array)	(sizeof(array) / sizeof((array)[0]))

/*
 * Each register's fields, GPFSEL0's first: a word the plan changes keeps only these bits, so
 * its reserved bits are clear and the generated write, which refuses them, takes it.
 */
static const uint32_t fields[ERX_BCM2711_PINS_REGISTERS] = {
	ERX_BCM2711_GPIO_GPFSEL0_PRESERVE, ERX_BCM2711_GPIO_GPFSEL1_PRESERVE, ERX_BCM2711_GPIO_GPFSEL2_PRESERVE,
	ERX_BCM2711_GPIO_GPFSEL3_PRESERVE, ERX_BCM2711_GPIO_GPFSEL4_PRESERVE, ERX_BCM2711_GPIO_GPFSEL5_PRESERVE,
};

/*
 * Each alternate's code, by alternate number. Every FSEL field takes the SVD's one FUNCTION
 * enumeration (derivedFrom), so FSEL0's values are every field's.
 */
static const uint32_t functions[] = {
	ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT0, ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT1, ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT2,
	ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT3, ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4, ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5,
};

/*
 * Writes code into GPIO gpio's field of *fsel; false for a pin outside banks 1 and 2. The
 * cases are the pins this core sets, so bank 0 is refused because it has none, and each
 * calls its field's generated setter directly: the C17 cores make no indirect call
 * (kernel/stack_targets.txt). GPFSEL2 holds GPIO 20 to 29, GPFSEL3 30 to 39, GPFSEL4 40 to
 * 49 and GPFSEL5 50 to 57.
 */
static bool
field_set(erx_bcm2711_fsel_t *fsel, uint32_t gpio, uint32_t code)
{
	switch (gpio) {
	case 28:
		return (erx_bcm2711_gpio_gpfsel2_fsel28_set(fsel->word[2], code, &fsel->word[2]));
	case 29:
		return (erx_bcm2711_gpio_gpfsel2_fsel29_set(fsel->word[2], code, &fsel->word[2]));
	case 30:
		return (erx_bcm2711_gpio_gpfsel3_fsel30_set(fsel->word[3], code, &fsel->word[3]));
	case 31:
		return (erx_bcm2711_gpio_gpfsel3_fsel31_set(fsel->word[3], code, &fsel->word[3]));
	case 32:
		return (erx_bcm2711_gpio_gpfsel3_fsel32_set(fsel->word[3], code, &fsel->word[3]));
	case 33:
		return (erx_bcm2711_gpio_gpfsel3_fsel33_set(fsel->word[3], code, &fsel->word[3]));
	case 34:
		return (erx_bcm2711_gpio_gpfsel3_fsel34_set(fsel->word[3], code, &fsel->word[3]));
	case 35:
		return (erx_bcm2711_gpio_gpfsel3_fsel35_set(fsel->word[3], code, &fsel->word[3]));
	case 36:
		return (erx_bcm2711_gpio_gpfsel3_fsel36_set(fsel->word[3], code, &fsel->word[3]));
	case 37:
		return (erx_bcm2711_gpio_gpfsel3_fsel37_set(fsel->word[3], code, &fsel->word[3]));
	case 38:
		return (erx_bcm2711_gpio_gpfsel3_fsel38_set(fsel->word[3], code, &fsel->word[3]));
	case 39:
		return (erx_bcm2711_gpio_gpfsel3_fsel39_set(fsel->word[3], code, &fsel->word[3]));
	case 40:
		return (erx_bcm2711_gpio_gpfsel4_fsel40_set(fsel->word[4], code, &fsel->word[4]));
	case 41:
		return (erx_bcm2711_gpio_gpfsel4_fsel41_set(fsel->word[4], code, &fsel->word[4]));
	case 42:
		return (erx_bcm2711_gpio_gpfsel4_fsel42_set(fsel->word[4], code, &fsel->word[4]));
	case 43:
		return (erx_bcm2711_gpio_gpfsel4_fsel43_set(fsel->word[4], code, &fsel->word[4]));
	case 44:
		return (erx_bcm2711_gpio_gpfsel4_fsel44_set(fsel->word[4], code, &fsel->word[4]));
	case 45:
		return (erx_bcm2711_gpio_gpfsel4_fsel45_set(fsel->word[4], code, &fsel->word[4]));
	case 46:
		return (erx_bcm2711_gpio_gpfsel4_fsel46_set(fsel->word[4], code, &fsel->word[4]));
	case 47:
		return (erx_bcm2711_gpio_gpfsel4_fsel47_set(fsel->word[4], code, &fsel->word[4]));
	case 48:
		return (erx_bcm2711_gpio_gpfsel4_fsel48_set(fsel->word[4], code, &fsel->word[4]));
	case 49:
		return (erx_bcm2711_gpio_gpfsel4_fsel49_set(fsel->word[4], code, &fsel->word[4]));
	case 50:
		return (erx_bcm2711_gpio_gpfsel5_fsel50_set(fsel->word[5], code, &fsel->word[5]));
	case 51:
		return (erx_bcm2711_gpio_gpfsel5_fsel51_set(fsel->word[5], code, &fsel->word[5]));
	case 52:
		return (erx_bcm2711_gpio_gpfsel5_fsel52_set(fsel->word[5], code, &fsel->word[5]));
	case 53:
		return (erx_bcm2711_gpio_gpfsel5_fsel53_set(fsel->word[5], code, &fsel->word[5]));
	case 54:
		return (erx_bcm2711_gpio_gpfsel5_fsel54_set(fsel->word[5], code, &fsel->word[5]));
	case 55:
		return (erx_bcm2711_gpio_gpfsel5_fsel55_set(fsel->word[5], code, &fsel->word[5]));
	case 56:
		return (erx_bcm2711_gpio_gpfsel5_fsel56_set(fsel->word[5], code, &fsel->word[5]));
	case 57:
		return (erx_bcm2711_gpio_gpfsel5_fsel57_set(fsel->word[5], code, &fsel->word[5]));
	default:
		return (false);
	}
}

/*
 * The plan is built in a copy, so a refused row leaves *fsel as read. Each setter takes a
 * 3-bit code of the enumeration, so a setter refuses only a pin it does not have. A word the
 * rows leave as read is not written, so it keeps whatever its reserved bits read.
 */
bool
erx_bcm2711_pins_plan(const erx_mf_pin_t *rows, size_t count, erx_bcm2711_fsel_t *fsel)
{
	erx_bcm2711_fsel_t next = *fsel;

	if (count > ERX_BCM2711_PINS_ROWS_MAX)
		return (false);
	for (size_t at = 0; at < count; at++)
		if (rows[at].alternate >= nitems(functions) || !field_set(&next, rows[at].pin, functions[rows[at].alternate]))
			return (false);
	for (uint32_t reg = 0; reg < ERX_BCM2711_PINS_REGISTERS; reg++)
		if (next.word[reg] != fsel->word[reg])
			next.word[reg] &= fields[reg];
	*fsel = next;
	return (true);
}
