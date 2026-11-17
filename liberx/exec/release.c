/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The release of a loader's window (release.h): one comparison of the
 * window with the program's own image, then one release through the
 * space's release call. The space skips the window's holes and removes
 * every mapping and reservation the window covers whole; the loader's
 * segments, the reservation erx_exec_load made and the record's mapping all
 * lie inside it.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/exec/release.h"

/*
 * Whether a and b share a byte. Neither end is computed, so a range that
 * ends at 2^64 compares as any other.
 */
static bool
meets(erx_exec_range_t a, erx_exec_range_t b)
{
	if (b.address <= a.address)
		return (a.address - b.address < b.size);
	return (b.address - a.address < a.size);
}

bool
erx_exec_release(erx_exec_range_t own)
{
	const erx_exec_range_t window = { .address = ERX_EXEC_WINDOW_BASE, .size = ERX_EXEC_WINDOW_BYTES };

	return (!meets(window, own) && erx_vm_release(ERX_CAP_SELF, window.address, window.size) == ERX_OK);
}
