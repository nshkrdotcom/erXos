/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The descriptor table's decisions (fd_plan.h): no lock, no global, only the arguments. */

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

#include "liberx/program/fd_plan.h"

/* The status flags a descriptor keeps (fd.h): what F_SETFL sets and F_GETFL reads back. */
#define STATUS_KEPT	(O_NONBLOCK | O_APPEND)

static bool
slot_held(const erx_prog_slot_t *slots, uint32_t nslots, long fd)
{
	return (fd >= 0 && fd < (long)nslots && slots[fd].obj != NULL);
}

int
erx_prog_dup_plan(const erx_prog_slot_t *slots, uint32_t nslots, erx_prog_dup_t req)
{
	const bool inside = req.at >= 0 && req.at < (long)nslots;

	/* dup3 refuses its own descriptor before it looks at either, as FreeBSD's libc does. */
	if (req.mode == ERX_PROG_DUP_AT && req.at == req.from)
		return (-EINVAL);
	if (req.from < 0)
		return (-EBADF);
	switch (req.mode) {
	case ERX_PROG_DUP_AT:
		if (!inside)
			return (-EBADF);
		return (slot_held(slots, nslots, req.from) ? (int)req.at : -EBADF);
	case ERX_PROG_DUP_LOWEST:
		if (!inside)
			return (-EINVAL);
		if (!slot_held(slots, nslots, req.from))
			return (-EBADF);
		for (uint32_t at = (uint32_t)req.at; at < nslots; at++) {
			if (slots[at].obj == NULL)
				return ((int)at);
		}
		return (-EMFILE);
	}
	return (-EINVAL);
}

int
erx_prog_dup3_req(int old, int to, int flags, erx_prog_dup_t *req)
{
	if ((flags & ~O_CLOEXEC) != 0)
		return (-EINVAL);
	*req = (erx_prog_dup_t){ .mode = ERX_PROG_DUP_AT, .from = old, .at = to,
	    .cloexec = (flags & O_CLOEXEC) != 0 };
	return (0);
}

int
erx_prog_fcntl_req(int fd, int cmd, long arg, erx_prog_fcntl_t *out)
{
	switch (cmd) {
	case F_DUPFD:
	case F_DUPFD_CLOEXEC:
		*out = (erx_prog_fcntl_t){ .op = ERX_PROG_FCNTL_DUP, .u.dup = { .mode = ERX_PROG_DUP_LOWEST,
		    .from = fd, .at = arg, .cloexec = cmd == F_DUPFD_CLOEXEC } };
		return (0);
	case F_GETFD:
		*out = (erx_prog_fcntl_t){ .op = ERX_PROG_FCNTL_GETFD };
		return (0);
	case F_SETFD:
		*out = (erx_prog_fcntl_t){ .op = ERX_PROG_FCNTL_SETFD, .u.cloexec = (arg & FD_CLOEXEC) != 0 };
		return (0);
	case F_GETFL:
		*out = (erx_prog_fcntl_t){ .op = ERX_PROG_FCNTL_GETFL };
		return (0);
	case F_SETFL:
		*out = (erx_prog_fcntl_t){ .op = ERX_PROG_FCNTL_SETFL, .u.status = arg };
		return (0);
	default:
		return (-EINVAL);
	}
}

int
erx_prog_async_set(bool on)
{
	return (on ? -EINVAL : 0);
}

int
erx_prog_status_set(long arg, uint32_t *status)
{
	const int refusal = erx_prog_async_set((arg & O_ASYNC) != 0);

	if (refusal != 0)
		return (refusal);
	*status = (uint32_t)(arg & STATUS_KEPT);
	return (0);
}

int
erx_prog_seek_plan(int64_t at, int64_t offset, int whence, int64_t end, int64_t *to)
{
	int64_t base;

	switch (whence) {
	case SEEK_SET:
		base = 0;
		break;
	case SEEK_CUR:
		base = at;
		break;
	case SEEK_END:
		base = end;
		break;
	default:
		return (-EINVAL);
	}
	if (__builtin_add_overflow(base, offset, to))
		return (-EOVERFLOW);
	return (*to < 0 ? -EINVAL : 0);
}
