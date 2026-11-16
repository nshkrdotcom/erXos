/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_EXEC_RANGE_H
#define LIBERX_EXEC_RANGE_H

#include <stdint.h>

/*
 * A range of the program's space: size bytes from address. A load holds
 * its view and its reservation as ranges until its outcome, size 0 holding
 * nothing (load.h); a program knows its own image as a range, which the
 * loader's window must not meet (release.h).
 */
typedef struct erx_exec_range {
	uint64_t	address;
	uint64_t	size;
} erx_exec_range_t;

#endif /* !LIBERX_EXEC_RANGE_H */
