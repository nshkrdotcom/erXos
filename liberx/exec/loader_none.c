/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The linked loader of a fixed-link task (release.h): none. A task the
 * session maps from the boot image, the loader erx_exec among them, is
 * never entered by a loader, so its span is size 0 and erx_exec_release
 * refuses any record such a task is handed.
 */

#include "liberx/exec/release.h"

erx_exec_range_t
erx_exec_loader(void)
{
	return ((erx_exec_range_t){ .address = 0, .size = 0 });
}
