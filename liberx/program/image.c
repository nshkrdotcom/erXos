/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The program's own image (program.h): in an executable, the range the
 * loader's window must not meet (erx_exec_release); in the loader
 * erx_exec, the start of its window, whose rest erx_exec_load reserves: from its file header, at the start of its
 * first segment, where the linker puts __ehdr_start, to erx_image_end,
 * which the task script (liberx/backend/fiasco/task.ld) sets at the end of
 * its last segment, rounded up to a whole page. Both symbols are
 * section-relative, so a position-independent link gives their addresses
 * where the program was loaded.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/program/program.h"

extern const char __ehdr_start[];
extern const char erx_image_end[];

erx_exec_range_t
erx_prog_image(void)
{
	const uint64_t start = (uint64_t)(uintptr_t)__ehdr_start;
	const uint64_t end = ((uint64_t)(uintptr_t)erx_image_end + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;

	return ((erx_exec_range_t){ .address = start, .size = end - start });
}
