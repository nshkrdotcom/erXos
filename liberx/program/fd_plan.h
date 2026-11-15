/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_FD_PLAN_H
#define LIBERX_PROGRAM_FD_PLAN_H

/*
 * The descriptor table's decisions (docs/design-programs.md, "Descriptors
 * and files"), pure functions of their arguments that fd.c applies under the
 * table lock: which slot a dup fills, what an fcntl command asks, the status
 * flags an F_SETFL leaves and where an lseek of a device moves its offset.
 * They answer as FreeBSD's kern_dup, kern_fcntl and vn_seek do
 * (sys/kern/kern_descrip.c, sys/kern/vfs_vnops.c) and its libc's dup3
 * (lib/libc/gen/dup3.c), in the errno values of the headers they build with.
 */

#include <stdbool.h>
#include <stdint.h>

struct erx_prog_obj;

/* A slot of the table: the object it holds a reference to, NULL when empty, and its FD_CLOEXEC. */
typedef struct erx_prog_slot {
	struct erx_prog_obj	*obj;
	bool			 cloexec;
} erx_prog_slot_t;

typedef enum erx_prog_dup_mode {
	ERX_PROG_DUP_LOWEST,	/* dup and F_DUPFD: the lowest empty slot at or above at */
	ERX_PROG_DUP_AT		/* dup3, and dup2 through it: slot at, closing what it holds */
} erx_prog_dup_mode_t;

/* A dup of descriptor from; the new slot's FD_CLOEXEC is cloexec. */
typedef struct erx_prog_dup {
	erx_prog_dup_mode_t	 mode;
	int			 from;
	long			 at;
	bool			 cloexec;
} erx_prog_dup_t;

/*
 * The slot req fills in a table of nslots slots, or a negative errno:
 * -EINVAL first for an AT slot equal to from, as dup3 refuses it; -EBADF
 * for a from that is negative or empty, and for an AT slot outside the
 * table; -EINVAL for a LOWEST bound outside the table, as F_DUPFD refuses it;
 * -EMFILE when no slot at or above a LOWEST bound is empty.  The slot an AT
 * dup fills may hold an object, which the dup closes.
 */
int	erx_prog_dup_plan(const erx_prog_slot_t *slots, uint32_t nslots, erx_prog_dup_t req);

/* dup3(old, to, flags) as a dup: 0 and *req, or -EINVAL for flags other than O_CLOEXEC. */
int	erx_prog_dup3_req(int old, int to, int flags, erx_prog_dup_t *req);

typedef enum erx_prog_fcntl_op {
	ERX_PROG_FCNTL_DUP,	/* F_DUPFD and F_DUPFD_CLOEXEC: u.dup */
	ERX_PROG_FCNTL_GETFD,
	ERX_PROG_FCNTL_SETFD,	/* u.cloexec */
	ERX_PROG_FCNTL_GETFL,
	ERX_PROG_FCNTL_SETFL	/* u.status, the call's argument */
} erx_prog_fcntl_op_t;

typedef struct erx_prog_fcntl {
	erx_prog_fcntl_op_t	 op;
	union {
		erx_prog_dup_t	 dup;
		bool		 cloexec;
		long		 status;
	} u;
} erx_prog_fcntl_t;

/*
 * fcntl(fd, cmd, arg) as one of the commands the table offers: 0 and *out,
 * or -EINVAL for any other command, before the descriptor is looked at, as
 * FreeBSD answers a command it does not know.  F_SETFD keeps FD_CLOEXEC of
 * arg and ignores its other bits, as FreeBSD's fd_to_fde_flags does.
 */
int	erx_prog_fcntl_req(int fd, int cmd, long arg, erx_prog_fcntl_t *out);

/*
 * The status flags an F_SETFL of arg leaves: 0 and *status, O_NONBLOCK and
 * O_APPEND as arg gives them, or -EINVAL when arg asks for O_ASYNC, since no
 * object signals its readiness, as FreeBSD's null device refuses FIOASYNC.
 * The access mode and every other bit are ignored, as FreeBSD and Linux
 * ignore what F_SETFL does not change.
 */
int	erx_prog_status_set(long arg, uint32_t *status);
/* Whether async I/O may be turned on (FIOASYNC, F_SETFL's O_ASYNC): 0 to turn it off, -EINVAL to turn it on. */
int	erx_prog_async_set(bool on);

/*
 * Where an lseek moves the offset of an object with a position but no
 * contents, null's: from at, by offset, relative to whence, with end the
 * size SEEK_END reads.  0 and *to; -EINVAL for a whence other than
 * SEEK_SET, SEEK_CUR and SEEK_END (SEEK_DATA and SEEK_HOLE included, as
 * FreeBSD answers them for a device without them) and for a negative
 * result, which a lseek's return could not tell from an errno; -EOVERFLOW
 * for a sum past off_t.
 */
int	erx_prog_seek_plan(int64_t at, int64_t offset, int whence, int64_t end, int64_t *to);

#endif /* !LIBERX_PROGRAM_FD_PLAN_H */
