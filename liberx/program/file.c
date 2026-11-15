/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * liberx's file client (file.h).  Each call writes its request's value,
 * a term of the request union's file cases (abi/protocols/prog.txt), and
 * makes the request through the channel; the generated profile types the
 * reply by the request's case.  The open's flags are decided whole by
 * open_plan, a pure function of the call's arguments, before anything is
 * sent.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>

#include "erx/abi.h"
#include "erx/etf.h"
#include "erx/prog_profile.h"
#include "liberx/program/channel.h"
#include "liberx/program/data.h"
#include "liberx/program/fd.h"
#include "liberx/program/file.h"
#include "liberx/program/pages.h"
#include "liberx/program/program.h"

/*
 * Every open on a 64-bit target is a large-file open; musl's open passes
 * O_LARGEFILE all the same.  The host's headers, for the host tests, have
 * none.
 */
#ifdef O_LARGEFILE
#define LARGEFILE	O_LARGEFILE
#else
#define LARGEFILE	0
#endif

/*
 * The open flags open_plan maps onto the request, and those it sends
 * nothing for: O_CLOEXEC is the slot's FD_CLOEXEC, and O_NONBLOCK, which
 * changes nothing for a regular file, is kept as the file's status alone.
 */
#define OPEN_MAPPED	(O_WRONLY | O_RDWR | O_CREAT | O_EXCL | O_TRUNC | O_APPEND | O_SYNC | O_DSYNC | \
			 O_DIRECTORY | O_NOFOLLOW)
#define OPEN_IGNORED	(O_CLOEXEC | O_NOCTTY | O_NONBLOCK | LARGEFILE)

/* A file request's value: {file, lcreate, Path, Flags, Mode} with the longest path, and its framing. */
#define VALUE_MAX	(ERX_PROG_PATH_MAX + 64)

/* What an open sends: its request's case, lopen or lcreate, its 9P2000.L flags and lcreate's mode. */
typedef struct open_plan {
	uint16_t	request;
	uint32_t	p9_flags;
	uint16_t	mode;
} open_plan_t;

/*
 * The request openat's flags and mode ask for, the mode less umask: 0 and
 * *plan, or -EINVAL for the access mode 3 and for a flag outside
 * OPEN_MAPPED and OPEN_IGNORED.  Flags travel as 9P2000.L's values
 * (abi/protocols/9p.txt), mapped one by one, never as the architecture's.
 * O_CREAT chooses lcreate, which alone carries O_EXCL, as Linux ignores
 * O_EXCL without O_CREAT; O_DSYNC asks for 9P2000.L's sync, which the ABI
 * offers alone and which promises more than O_DSYNC does.  O_DIRECTORY and
 * O_NOFOLLOW travel as they are, whatever O_CREAT: the handler decides what
 * they mean with it, as FreeBSD's vn_open_cred does.
 */
static int
open_plan(int flags, mode_t mode, uint16_t umask, open_plan_t *plan)
{
	const int access = flags & (O_WRONLY | O_RDWR);
	const bool create = (flags & O_CREAT) != 0;
	uint32_t p9 = 0;

	if ((flags & ~(OPEN_MAPPED | OPEN_IGNORED)) != 0 || access == (O_WRONLY | O_RDWR))
		return (-EINVAL);
	if (access == O_WRONLY)
		p9 |= ERX_P9_O_WRONLY;
	if (access == O_RDWR)
		p9 |= ERX_P9_O_RDWR;
	if (create && (flags & O_EXCL) != 0)
		p9 |= ERX_P9_O_EXCL;
	if ((flags & O_TRUNC) != 0)
		p9 |= ERX_P9_O_TRUNC;
	if ((flags & O_APPEND) != 0)
		p9 |= ERX_P9_O_APPEND;
	if ((flags & (O_SYNC | O_DSYNC)) != 0)
		p9 |= ERX_P9_O_SYNC;
	if ((flags & O_DIRECTORY) != 0)
		p9 |= ERX_P9_O_DIRECTORY;
	if ((flags & O_NOFOLLOW) != 0)
		p9 |= ERX_P9_O_NOFOLLOW;
	*plan = (open_plan_t){
		.request = create ? ERX_PROG_REQUEST_FILE_LCREATE : ERX_PROG_REQUEST_FILE_LOPEN,
		.p9_flags = p9,
		.mode = create ? (uint16_t)(mode & ~(mode_t)umask & 07777) : 0,
	};
	return (0);
}

/*
 * Whether a relative path may be resolved from dirfd: 0 for AT_FDCWD, the
 * working directory the handler keeps, -EBADF for a descriptor the table
 * does not hold and -ENOTDIR for every object it holds, since the request
 * names no directory but the working directory (a directory opened with
 * O_DIRECTORY included: TODO.md).
 */
static int
dirfd_check(int dirfd)
{
	erx_prog_obj_t *obj;
	int result = -ENOTDIR;

	if (dirfd == AT_FDCWD)
		return (0);
	if ((obj = erx_prog_fd_get(dirfd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_PIPE:
	case ERX_PROG_OBJ_MEM:
	case ERX_PROG_OBJ_FILE:
		result = -ENOTDIR;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

/* Starts a file request's value: its tuple of arity items, the atom file and the operation op. */
static void
value_start(erx_etf_writer_t *w, uint8_t *value, uint32_t arity, const char *op)
{
	erx_etf_writer_init(w, value, VALUE_MAX);
	erx_etf_put_tuple(w, arity);
	erx_etf_put_atom(w, "file", strlen("file"));
	erx_etf_put_atom(w, op, strlen(op));
}

/* A file request's reply_fn: a file reply holds no list, so a copy outlives its frame. */
static void
reply_copy(const erx_prog_reply_t *reply, void *arg)
{
	*(erx_prog_reply_t *)arg = *reply;
}

/* Makes the request whose value w holds: 0 and *reply, or -EIO when it is not made. */
static int
request(uint16_t which, erx_etf_writer_t *w, const uint8_t *value, erx_prog_reply_t *reply)
{
	size_t len;

	if (!erx_etf_writer_done(w, &len))
		return (-EIO);
	if (erx_prog_channel_request(which, value, len, reply_copy, reply) != ERX_OK)
		return (-EIO);
	return (0);
}

/* An open's request: 0 and *open, or a negative errno. */
static int
open_request(const char *path, size_t path_len, const open_plan_t *plan, uint16_t *open)
{
	uint8_t value[VALUE_MAX];
	const erx_prog_open_reply_t *answer;
	erx_prog_reply_t reply;
	erx_etf_writer_t w;
	int status;

	if (plan->request == ERX_PROG_REQUEST_FILE_LCREATE) {
		value_start(&w, value, 5, "lcreate");
		erx_etf_put_binary(&w, path, path_len);
		erx_etf_put_integer(&w, plan->p9_flags);
		erx_etf_put_integer(&w, plan->mode);
		answer = &reply.u.file_lcreate;
	} else {
		value_start(&w, value, 4, "lopen");
		erx_etf_put_binary(&w, path, path_len);
		erx_etf_put_integer(&w, plan->p9_flags);
		answer = &reply.u.file_lopen;
	}
	if ((status = request(plan->request, &w, value, &reply)) != 0)
		return (status);
	if (answer->which == ERX_PROG_OPEN_REPLY_ERROR)
		return (-answer->u.error.errnum);
	*open = answer->u.ok.open;
	return (0);
}

/* {file, clunk, Open}: 0, or a negative errno. */
static int
clunk(uint16_t open)
{
	uint8_t value[VALUE_MAX];
	erx_prog_reply_t reply;
	erx_etf_writer_t w;
	int status;

	value_start(&w, value, 3, "clunk");
	erx_etf_put_integer(&w, open);
	if ((status = request(ERX_PROG_REQUEST_FILE_CLUNK, &w, value, &reply)) != 0)
		return (status);
	return (reply.u.file_clunk.which == ERX_PROG_CLUNK_REPLY_ERROR ? -reply.u.file_clunk.u.error.errnum : 0);
}

int
erx_prog_file_openat(int dirfd, const char *path, int flags, mode_t mode)
{
	erx_prog_file_t *file;
	open_plan_t plan;
	size_t path_len;
	uint16_t open;
	int fd, status;

	if (path == NULL)
		return (-EFAULT);
	path_len = strnlen(path, (size_t)ERX_PROG_PATH_MAX + 1);
	if (path_len == 0)
		return (-ENOENT);
	if (path_len > ERX_PROG_PATH_MAX)
		return (-ENAMETOOLONG);
	if (path[0] != '/') {
		status = dirfd_check(dirfd);
		if (status != 0)
			return (status);
	}
	status = open_plan(flags, mode, erx_prog_self()->umask, &plan);
	if (status != 0)
		return (status);
	/* The object and the slot come before the request, so an open that cannot be kept is never made. */
	if ((file = erx_prog_pages_take(sizeof(*file))) == NULL)
		return (-ENOMEM);
	if ((fd = erx_prog_fd_reserve()) < 0) {
		erx_prog_pages_give(file, sizeof(*file));
		return (fd);
	}
	status = open_request(path, path_len, &plan, &open);
	if (status != 0) {
		erx_prog_fd_unreserve(fd);
		erx_prog_pages_give(file, sizeof(*file));
		return (status);
	}
	*file = (erx_prog_file_t){
		.obj = { .kind = ERX_PROG_OBJ_FILE, .status = (uint32_t)(flags & (O_APPEND | O_NONBLOCK)) },
		.open = open,
		.access = flags & (O_WRONLY | O_RDWR),
	};
	erx_prog_fd_fill(fd, &file->obj, (flags & O_CLOEXEC) != 0);
	return (fd);
}

/*
 * One part of a read or a write, count bytes through data slot slot: 0 and
 * *done, at most count, or a negative errno.
 */
static int
io(uint16_t which, uint16_t open, uint32_t count, uint32_t slot, uint32_t *done)
{
	const bool reading = which == ERX_PROG_REQUEST_FILE_READ;
	uint8_t value[VALUE_MAX];
	const erx_prog_io_reply_t *answer;
	erx_prog_reply_t reply;
	erx_etf_writer_t w;
	int status;

	value_start(&w, value, 5, reading ? "read" : "write");
	erx_etf_put_integer(&w, open);
	erx_etf_put_integer(&w, count);
	erx_etf_put_integer(&w, slot);
	if ((status = request(which, &w, value, &reply)) != 0)
		return (status);
	answer = reading ? &reply.u.file_read : &reply.u.file_write;
	if (answer->which == ERX_PROG_IO_REPLY_ERROR)
		return (-answer->u.error.errnum);
	/*
	 * The profile bounds the count by a slot; only the request knows its own
	 * count.  A write that took nothing would make a caller that writes the
	 * rest, as stdio does, ask again for ever.
	 */
	if (answer->u.ok.io_done > count)
		return (-EIO);
	if (!reading && answer->u.ok.io_done == 0)
		return (-EIO);
	*done = answer->u.ok.io_done;
	return (0);
}

/*
 * A read or a write of len bytes, 1 to SSIZE_MAX, at buf, in parts through
 * one data slot.  A read copies each part's bytes out of the slot after its
 * reply, a write copies them in before its request.
 */
static ssize_t
transfer(erx_prog_file_t *file, uint16_t which, uint8_t *buf, size_t len)
{
	const uint32_t slot = erx_prog_data_take();
	uint8_t *const bytes = erx_prog_data_bytes(slot);
	ssize_t result = 0;
	size_t total = 0;

	while (total < len) {
		const uint32_t part = len - total < ERX_PROG_DATA_SLOT_BYTES ? (uint32_t)(len - total) :
		    ERX_PROG_DATA_SLOT_BYTES;
		uint32_t done;
		int status;

		if (which == ERX_PROG_REQUEST_FILE_WRITE)
			memcpy(bytes, buf + total, part);
		if ((status = io(which, file->open, part, slot, &done)) != 0) {
			result = status;
			break;
		}
		if (which == ERX_PROG_REQUEST_FILE_READ)
			memcpy(buf + total, bytes, done);
		total += done;
		if (done < part)
			break;
	}
	erx_prog_data_give(slot);
	return (total > 0 ? (ssize_t)total : result);
}

erx_prog_file_t *
erx_prog_file_of(erx_prog_obj_t *obj)
{
	return ((erx_prog_file_t *)obj);
}

ssize_t
erx_prog_file_read(erx_prog_file_t *file, void *buf, size_t len)
{
	return (transfer(file, ERX_PROG_REQUEST_FILE_READ, buf, len));
}

ssize_t
erx_prog_file_write(erx_prog_file_t *file, const void *buf, size_t len)
{
	/* transfer only reads buf for a write. */
	return (transfer(file, ERX_PROG_REQUEST_FILE_WRITE, (uint8_t *)(uintptr_t)buf, len));
}

void
erx_prog_file_release(erx_prog_file_t *file)
{
	(void)clunk(file->open);
	erx_prog_pages_give(file, sizeof(*file));
}
