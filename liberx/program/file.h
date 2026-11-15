/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_FILE_H
#define LIBERX_PROGRAM_FILE_H

/*
 * liberx's file client (docs/design-files.md, "Native clients: liberx's
 * file client"; docs/design-programs.md, "Descriptors and files"): a file
 * object of the descriptor table (fd.h) names an open of the program's
 * handler, the number the handler gave at its open, which names an
 * open-file description in the session.  The handler keeps the program's
 * namespace, working directory, descriptions and their offsets; liberx
 * keeps no path, fid or offset, so several descriptors share one object
 * and dup costs no request.  Every call here is a request on the program's
 * channel (channel.h) whose reply its thread waits for, and the bytes of a
 * read or a write move through a slot of the data area (data.h), never
 * across the channel.  Only workers make these calls; the event executor
 * never holds a file.
 *
 * A request the channel cannot carry, and a reply that breaks the
 * protocol's rules (a count past the one asked for, or a write that took
 * nothing), fail with -EIO.  An
 * error the handler answers is returned as its negative errno, whose number
 * the ABI's errno table gives as musl's errno.h does.
 */

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "liberx/program/fd.h"

/* A file: the table's object head, first, and the handler's open. */
typedef struct erx_prog_file {
	erx_prog_obj_t	 obj;
	uint16_t	 open;
	int		 access;	/* O_RDONLY, O_WRONLY or O_RDWR, which F_GETFL reads */
} erx_prog_file_t;

/* The file obj heads; obj is of kind ERX_PROG_OBJ_FILE. */
erx_prog_file_t	*erx_prog_file_of(erx_prog_obj_t *obj);

/*
 * openat(dirfd, path, flags, mode): a request to open path, or with O_CREAT
 * to create it with mode less the program's umask, then a file object in
 * the lowest empty slot.  The slot's number, or a negative errno:
 *
 * - -EFAULT for a NULL path, -ENOENT for an empty one and -ENAMETOOLONG for
 *   one of more than ERX_PROG_PATH_MAX bytes before its NUL;
 * - for a relative path, -EBADF when dirfd is neither AT_FDCWD nor a
 *   descriptor the table holds, and -ENOTDIR when it holds one, since no
 *   object of the table is a directory; an absolute path ignores dirfd;
 * - -EINVAL for the access mode O_WRONLY | O_RDWR and for any flag the
 *   handler's request cannot carry, O_DIRECTORY, O_NOFOLLOW, O_NONBLOCK and
 *   O_PATH among them;
 * - the handler's errno for a refused open;
 * - -ENOMEM when no memory holds the object, and -EMFILE when the table has
 *   no empty slot, both before any request, so the open is never made.
 *
 * O_CLOEXEC and O_NOCTTY change nothing a file's open sends (O_CLOEXEC is
 * the table's), and O_LARGEFILE is every open's on a 64-bit target.
 */
int	erx_prog_file_openat(int dirfd, const char *path, int flags, mode_t mode);

/*
 * read and write of len bytes, 1 to SSIZE_MAX, at the description's
 * offset: one data slot for the call and a request for each part of at
 * most ERX_PROG_DATA_SLOT_BYTES, until a part moves fewer bytes than it
 * asked for.  The bytes moved, or the first part's negative errno when none
 * moved.
 */
ssize_t	erx_prog_file_read(erx_prog_file_t *file, void *buf, size_t len);
ssize_t	erx_prog_file_write(erx_prog_file_t *file, const void *buf, size_t len);
/*
 * pread and pwrite: as read and write, at offset, 0 to OFF_MAX, and each
 * part after the bytes the parts before it moved, leaving the description's
 * offset where it was.  A part that would start past OFF_MAX is not made.
 */
ssize_t	erx_prog_file_pread(erx_prog_file_t *file, void *buf, size_t len, off_t offset);
ssize_t	erx_prog_file_pwrite(erx_prog_file_t *file, const void *buf, size_t len, off_t offset);
/*
 * lseek: {local, seek, Open, Offset, Whence}, which moves the description's
 * offset as FreeBSD's vn_seek moves a regular file's.  The offset reached,
 * or a negative errno: -EINVAL for a whence other than SEEK_SET, SEEK_CUR
 * and SEEK_END, sending nothing, and the handler's -EINVAL for a negative
 * result and -EOVERFLOW for one past OFF_MAX.
 */
off_t	erx_prog_file_seek(erx_prog_file_t *file, off_t offset, int whence);

/*
 * Lets go of a file whose last reference went: {file, clunk, Open}, whose
 * error, if any, no caller is left to take, then the object's memory.
 */
void	erx_prog_file_release(erx_prog_file_t *file);

#endif /* !LIBERX_PROGRAM_FILE_H */
