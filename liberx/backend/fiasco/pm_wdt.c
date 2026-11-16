/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/pm_wdt.h"
#include "erx/hw/pm_wdt.h"
#include "erx/mmio.h"
#include "liberx/backend/fiasco/pm_wdt.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/vm.h"

bool
erx_fiasco_pm_wdt_open(erx_dt_window_t window, erx_fiasco_pm_wdt_t *wdt)
{
	const uint64_t offset = window.base & (ERX_PAGE_SIZE - 1);
	erx_mmio_t device;
	uintptr_t page;
	uint32_t word;

	*wdt = (erx_fiasco_pm_wdt_t){ .armed = false };
	if (erx_fiasco_vm_device_page(window.base - offset, &page) != ERX_OK)
		return (false);
	/* The registers lie in the window's first page: a window running past it is cut there. */
	device.base = (volatile uint8_t *)(page + offset);
	device.length = (size_t)(window.size < ERX_PAGE_SIZE - offset ? window.size : ERX_PAGE_SIZE - offset);
	/* A read is harmless; the accessors refuse a register past the window's length. */
	if (!erx_pm_wdt_rstc_read(device, &word))
		return (false);
	if (!erx_pm_wdt_wdog_read(device, &word))
		return (false);
	wdt->device = device;
	return (true);
}

/*
 * WDOG first, then RSTC, as both sources write them; armed only once both are written.
 * The open read both registers, and erx_pm_wdt_words writes only declared fields, so no accessor refuses.
 */
void
erx_fiasco_pm_wdt_step(erx_fiasco_pm_wdt_t *wdt, erx_watchdog_action_t action)
{
	uint32_t rstc;

	if (wdt->device.length == 0 || !erx_pm_wdt_writes(action, wdt->armed, erx_fiasco_end_taken()))
		return;
	if (!erx_pm_wdt_rstc_read(wdt->device, &rstc))
		return;
	const erx_pm_wdt_words_t words = erx_pm_wdt_words(rstc);

	if (!erx_pm_wdt_wdog_write(wdt->device, words.wdog))
		return;
	if (!erx_pm_wdt_rstc_write(wdt->device, words.rstc))
		return;
	wdt->armed = true;
}
