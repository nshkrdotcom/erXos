/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/bcm2711_pins.h"
#include "erx/hw/bcm2711_gpio.h"
#include "erx/mmio.h"
#include "liberx/backend/fiasco/bcm2711_pins.h"
#include "liberx/backend/fiasco/vm.h"

/* GPFSEL0 to GPFSEL5's accessors, in register order. */
static bool (*const readers[ERX_BCM2711_PINS_REGISTERS])(erx_mmio_t, uint32_t *) = {
	erx_bcm2711_gpio_gpfsel0_read, erx_bcm2711_gpio_gpfsel1_read, erx_bcm2711_gpio_gpfsel2_read,
	erx_bcm2711_gpio_gpfsel3_read, erx_bcm2711_gpio_gpfsel4_read, erx_bcm2711_gpio_gpfsel5_read,
};
static bool (*const writers[ERX_BCM2711_PINS_REGISTERS])(erx_mmio_t, uint32_t) = {
	erx_bcm2711_gpio_gpfsel0_write, erx_bcm2711_gpio_gpfsel1_write, erx_bcm2711_gpio_gpfsel2_write,
	erx_bcm2711_gpio_gpfsel3_write, erx_bcm2711_gpio_gpfsel4_write, erx_bcm2711_gpio_gpfsel5_write,
};

/* Reads the six words; false when a register lies past the window. A read changes nothing. */
static bool
fsel_read(erx_mmio_t device, erx_bcm2711_fsel_t *fsel)
{
	for (uint32_t reg = 0; reg < ERX_BCM2711_PINS_REGISTERS; reg++)
		if (!readers[reg](device, &fsel->word[reg]))
			return (false);
	return (true);
}

/*
 * Only the words the plan changes are written, so a register whose fields no row names is
 * never written at all. A generated write refuses only a register past the window or a word
 * with reserved bits set: the reads proved every register lies in the window, and the plan
 * clears the reserved bits of each word it changes, so every write is taken.
 */
erx_fiasco_board_pins_t
erx_fiasco_bcm2711_pins_apply(erx_mmio_t device, const erx_mf_onboard_pin_t *rows, size_t count)
{
	erx_bcm2711_fsel_t read, planned, after;

	if (!fsel_read(device, &read))
		return (ERX_FIASCO_BOARD_PINS_REFUSED);
	planned = read;
	if (!erx_bcm2711_pins_plan(rows, count, &planned))
		return (ERX_FIASCO_BOARD_PINS_REFUSED);
	for (uint32_t reg = 0; reg < ERX_BCM2711_PINS_REGISTERS; reg++)
		if (planned.word[reg] != read.word[reg])
			(void)writers[reg](device, planned.word[reg]);
	if (!fsel_read(device, &after))
		return (ERX_FIASCO_BOARD_PINS_MISMATCH);
	for (uint32_t reg = 0; reg < ERX_BCM2711_PINS_REGISTERS; reg++)
		if (after.word[reg] != planned.word[reg])
			return (ERX_FIASCO_BOARD_PINS_MISMATCH);
	return (ERX_FIASCO_BOARD_PINS_SET);
}

erx_fiasco_board_pins_t
erx_fiasco_bcm2711_pins_set(erx_dt_window_t window, const erx_mf_onboard_pin_t *rows, size_t count)
{
	const uint64_t offset = window.base & (ERX_PAGE_SIZE - 1);
	erx_mmio_t device;
	uintptr_t page;

	if (erx_fiasco_vm_device_page(window.base - offset, &page) != ERX_OK)
		return (ERX_FIASCO_BOARD_PINS_REFUSED);
	/* The registers lie in the window's first page: a window running past it is cut there. */
	device.base = (volatile uint8_t *)(page + offset);
	device.length = (size_t)(window.size < ERX_PAGE_SIZE - offset ? window.size : ERX_PAGE_SIZE - offset);
	return (erx_fiasco_bcm2711_pins_apply(device, rows, count));
}
