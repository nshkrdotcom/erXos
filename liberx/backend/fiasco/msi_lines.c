/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/msi_lines.h"

int
erx_fiasco_msi_line_take(erx_fiasco_msi_range_t range, erx_fiasco_msi_held_t held, const void *context, uint32_t *line)
{
	if (range.count == 0)
		return (ERX_ENOTSUP);
	for (uint32_t offset = 0; offset < range.count; offset++) {
		if (!held(range.first + offset, context)) {
			*line = range.first + offset;
			return (ERX_OK);
		}
	}
	return (ERX_ELIMIT);
}
