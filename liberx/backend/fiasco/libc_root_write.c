/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A root's standard output and standard error are its own diagnostic text, which reaches
 * the console as debug log records of its space, as a domain's does (output_line.h). Alone
 * in its file: musl refers to this from every stdio call, and a program links liberxroot.a
 * ahead of its own objects, so a member here that reached the start path would bring
 * runtime_main.c's main ahead of the program's.
 */

#include <stdbool.h>
#include <stddef.h>

#include "liberx/libc_spawn.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/output_line.h"

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_output_write(bytes, length);
}

/* No descriptor table: musl's own rows answer every call (libc_start.h). */
bool
erx_fiasco_libc_fd(long n, const long args[6], long *result)
{
	(void)n;
	(void)args;
	(void)result;
	return (false);
}

/* No processes: musl's posix_spawn answers ENOSYS (libc_spawn.h). */
bool
erx_libc_spawn(const struct erx_spawn_request *req, long *result)
{
	(void)req;
	(void)result;
	return (false);
}
