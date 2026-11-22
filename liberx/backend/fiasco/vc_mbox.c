/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/hw/vc_mbox.h"
#include "erx/mmio.h"
#include "liberx/backend/fiasco/vc_mbox.h"
#include "liberx/backend/fiasco/vm.h"

/* The mailbox's registers for the boot; length 0 while the root keeps none. */
static erx_mmio_t vc_mbox_device;

bool
erx_fiasco_vc_mbox_open(erx_dt_window_t window)
{
	const uint64_t offset = window.base & (ERX_PAGE_SIZE - 1);
	erx_mmio_t device;
	uintptr_t page;
	uint32_t word;

	vc_mbox_device = (erx_mmio_t){ .base = NULL, .length = 0 };
	if (erx_fiasco_vm_device_page(window.base - offset, &page) != ERX_OK)
		return (false);
	/* The registers lie in the window's first page: a window running past it is cut there. */
	device.base = (volatile uint8_t *)(page + offset);
	device.length = (size_t)(window.size < ERX_PAGE_SIZE - offset ? window.size : ERX_PAGE_SIZE - offset);
	/*
	 * A read of STATUS changes nothing. The accessors refuse a register past the window's
	 * length, so a window too short for STATUS fails here, and one too short for WRITE fails
	 * at that write, before anything is posted.
	 */
	if (!erx_vc_mbox_status_read(device, &word))
		return (false);
	vc_mbox_device = device;
	return (true);
}

bool
erx_fiasco_vc_mbox_kept(void)
{
	return (vc_mbox_device.length != 0);
}
