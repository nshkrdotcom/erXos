/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_FD_H
#define LIBERX_PROGRAM_FD_H

/*
 * A program's descriptor table (docs/design-programs.md, "Descriptors and
 * files"): ERX_PROG_FDS_MAX slots, each empty or holding a reference to an
 * object of one of a closed set of kinds.  The table has one lock, which
 * guards its slots, every object's count of references and the list of the
 * objects reports can name, and is never held across a wait.  A call takes
 * a counted reference under the lock and works on the object after letting
 * the lock go, so a close empties its slot at once and the object goes with
 * its last reference, whichever thread drops it.
 *
 * The event executor never takes a counted reference: it finds the pipe end
 * a report names under the table lock and locks the end before it lets the
 * table lock go (erx_prog_fd_find_end), so an end it holds cannot be let go
 * under it.  The lock order is the table's, then an end's.
 *
 * Every operation is a switch on the object's kind with no default arm, so
 * a new kind makes the compiler name each operation that must handle it.
 */

#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>

#include <erx/prog_profile.h>

#include "liberx/program/fd_plan.h"

struct erx_pipe_end;

typedef enum erx_prog_obj_kind {
	ERX_PROG_OBJ_NULL,	/* null, an open of /dev/null with an offset of its own (fd.c) */
	ERX_PROG_OBJ_PIPE,	/* a pipe end, the head of an erx_pipe_end_t */
	ERX_PROG_OBJ_MEM,	/* a mem range the session mapped into the program (fd.c) */
	ERX_PROG_OBJ_FILE	/* an open of the handler's, the head of an erx_prog_file_t (file.h) */
} erx_prog_obj_kind_t;

/*
 * The head of every object, which is an open: what the slots a dup made
 * of one descriptor share.  refs counts the slots and the calls in
 * progress that hold it; prev and next link it into the table's list of
 * objects that reports name.  All three are the table lock's.  status is
 * the open's status flags, O_NONBLOCK and O_APPEND (fd_plan.h), which
 * F_SETFL and FIONBIO change under the table lock and calls load whole
 * with an atomic load, so a pipe call reads its O_NONBLOCK under the end's
 * lock alone.
 */
typedef struct erx_prog_obj {
	erx_prog_obj_kind_t	 kind;
	uint32_t		 refs;
	uint32_t		 status;
	struct erx_prog_obj	*prev;
	struct erx_prog_obj	*next;
} erx_prog_obj_t;

/* Whether obj's open has O_NONBLOCK: a call that would wait fails with -EAGAIN instead. */
static inline bool
erx_prog_obj_nonblock(const erx_prog_obj_t *obj)
{
	return ((__atomic_load_n(&obj->status, __ATOMIC_RELAXED) & O_NONBLOCK) != 0);
}

/*
 * Builds the table from the startup message's descriptors, which the plan
 * accepted (startup.h): a null object of its own for each null, an end object set up from
 * its descriptor for a pipe's read or write end, and a mem object for a mem
 * range, which names memory the session already mapped and maps nothing.  The event executor
 * calls it before main, alone.  ERX_OK, or the status of the first
 * descriptor that could not be set up, after which the program stops.
 */
int	erx_prog_fd_setup(erx_prog_fds_iter_t fds);

/* A counted reference to the object in slot fd, or NULL for an empty or out-of-range slot. */
erx_prog_obj_t	*erx_prog_fd_get(int fd);
/* Drops a reference erx_prog_fd_get took; the last one lets the object go. */
void	erx_prog_obj_put(erx_prog_obj_t *obj);
/* -EBADF when slot fd is empty or out of range, else what: the answer of a call whose object changes nothing. */
long	erx_prog_fd_held_or(int fd, long what);
/*
 * A spawn's snapshot of the whole table (docs/design-programs.md, "Starting a
 * program"), under one hold of the table lock, so no dup or close lands
 * halfway: each slot's object with a counted reference, which the caller
 * drops with erx_prog_obj_put, or NULL for an empty slot, and its FD_CLOEXEC.
 */
void	erx_prog_fd_snapshot(erx_prog_slot_t table[ERX_PROG_FDS_MAX]);
/*
 * The dups (fd_plan.h, erx_prog_dup_plan): a new slot holds a counted
 * reference to from's object, and FD_CLOEXEC as the call gives it, which a
 * dup never copies.  dup takes the lowest empty slot, without FD_CLOEXEC;
 * dup3 takes slot to, closing what it held as close does, with FD_CLOEXEC
 * when flags has O_CLOEXEC.  The slot, or a negative errno.
 */
int	erx_prog_fd_dup(int from);
int	erx_prog_fd_dup3(int from, int to, int flags);
/*
 * fcntl of slot fd: F_DUPFD and F_DUPFD_CLOEXEC, a dup to the lowest empty
 * slot at or above arg; F_GETFD and F_SETFD, the slot's FD_CLOEXEC; F_GETFL,
 * the open's access mode and status flags, and F_SETFL, its status flags
 * (fd_plan.h), but -EINVAL for a change of a file's O_APPEND, which its open
 * fixes.  A pipe's read end is O_RDONLY and its write end O_WRONLY,
 * all each allows (FreeBSD's ends are both O_RDWR); null and a mem range are
 * O_RDWR.  The command's answer, or a negative errno: -EINVAL for any other
 * command, and -EBADF for an empty slot.
 */
long	erx_prog_fd_fcntl(int fd, int cmd, long arg);
/*
 * pipe2's install: puts objs[0] and objs[1], each with a new reference,
 * into the two lowest empty slots, both or neither, with FD_CLOEXEC set to
 * cloexec, and their slots into fds[]: 0, or -EMFILE with nothing put.
 */
int	erx_prog_fd_install_pair(erx_prog_obj_t *const objs[2], bool cloexec, int fds[2]);
/*
 * An open's slot (docs/design-programs.md, "Descriptors and files"): the
 * lowest empty slot, reserved while the open makes its object, or -EMFILE.
 * A reserved slot is taken by no other open, dup or pipe, holds no object,
 * so every call on its number finds none, and a dup3 onto it is -EBUSY.
 * The open then fills it with its new object, which no slot or call holds
 * yet, with FD_CLOEXEC as cloexec gives it, or gives it back; filling or
 * giving back a slot that is not reserved stops the program.
 */
int	erx_prog_fd_reserve(void);
void	erx_prog_fd_fill(int fd, erx_prog_obj_t *obj, bool cloexec);
void	erx_prog_fd_unreserve(int fd);
/* Empties slot fd and drops its reference: 0 or -EBADF. */
int	erx_prog_fd_close(int fd);
/*
 * read and write on slot fd, holding a counted reference for the call: a
 * count or a negative errno, -EBADF for an empty slot and -EINVAL for a
 * len above SSIZE_MAX, as FreeBSD refuses it.  null reads as the end of
 * the stream and takes every byte written, as /dev/null does.  A mem range
 * is no stream: both fail with -ESPIPE.  A file reads and writes through
 * its handler (file.h).
 */
ssize_t	erx_prog_fd_read(int fd, void *buf, size_t len);
ssize_t	erx_prog_fd_write(int fd, const void *buf, size_t len);
/*
 * readv and writev of slot fd, holding one counted reference for the call:
 * the bytes moved or a negative errno; -EINVAL for a count outside 0 to
 * IOV_MAX or lengths that sum past SSIZE_MAX, before anything moves, and
 * -EBADF for an empty slot even with no entries.  A read is of the first
 * entry with bytes to take, so it never waits again with bytes in hand
 * (musl's stdio reads with a two-entry readv).  A write whose entries sum to
 * at most ERX_PIPE_BUF bytes is one write of them gathered, so it is atomic
 * against other writers of a pipe, as PIPE_BUF promises; a longer one writes
 * entry by entry and ends at a short write, as a short transfer ends POSIX's,
 * and at an error, which is its answer whatever went before, as
 * erx_pipe_write answers, but for -EAGAIN after bytes, which is their count.
 */
ssize_t	erx_prog_fd_readv(int fd, const struct iovec *iov, int count);
ssize_t	erx_prog_fd_writev(int fd, const struct iovec *iov, int count);

/*
 * mmap of slot fd (docs/design-programs.md#the-startup-message).  Only a
 * mem range maps, and it is mapped already: with flags MAP_SHARED alone,
 * offset 0, a len of 1 to the range's bytes and prot within PROT_READ |
 * PROT_WRITE, *addr is the address the session mapped it at.  0, or
 * -EBADF for an empty slot, -ENODEV for an object of another kind, -EINVAL
 * for any other flags, offset or len, and -EACCES for any other prot.  The
 * program's seam refuses PROT_EXEC before an mmap reaches the table.
 */
int	erx_prog_fd_mmap(int fd, size_t len, int prot, int flags, off_t offset, void **addr);
/*
 * fstat of slot fd: 0, or -EBADF for an empty slot.  null is a character
 * device of mode 0666, a pipe end a FIFO of mode 0600 and size 0, and a mem
 * range a regular file of mode 0600 whose size is its bytes (their parity
 * with FreeBSD is unverified, TODO.md).  Every other field is 0.  A file's
 * attributes need a request the protocol does not offer: -ENOSYS.
 */
int	erx_prog_fd_fstat(int fd, struct stat *st);

/*
 * lseek of slot fd: null's new offset, which only an lseek moves, as
 * FreeBSD's /dev/null keeps one (erx_prog_seek_plan, with no contents to
 * end at), a file's, which its description moves (erx_prog_file_seek),
 * -ESPIPE for a pipe end or a mem range, whatever whence, as FreeBSD's
 * kern_lseek answers an object that is not seekable, and -EBADF for an
 * empty slot.
 */
off_t	erx_prog_fd_lseek(int fd, off_t offset, int whence);
/*
 * pread and pwrite of len bytes of slot fd at offset, which move no offset,
 * as FreeBSD's kern_pread and kern_preadv do: -EINVAL for a len past
 * SSIZE_MAX, -EBADF for an empty slot, -ESPIPE for a pipe end or a mem
 * range, which are not seekable, then -EINVAL for a negative offset, but on null,
 * a character device, which reads nothing and takes every byte at any
 * offset; a file's bytes are erx_prog_file_pread's and erx_prog_file_pwrite's.
 */
ssize_t	erx_prog_fd_pread(int fd, void *buf, size_t len, off_t offset);
ssize_t	erx_prog_fd_pwrite(int fd, const void *buf, size_t len, off_t offset);
/*
 * ioctl of slot fd, with the generic requests of FreeBSD's kern_ioctl:
 * FIOCLEX and FIONCLEX set and clear the slot's FD_CLOEXEC, FIONBIO sets or
 * clears O_NONBLOCK as the int at arg is nonzero or not, and FIOASYNC with
 * a nonzero int is -EINVAL, as F_SETFL's O_ASYNC is.  0, -ENOTTY for any
 * other request, since no kind is a terminal, or -EBADF for an empty slot.
 */
int	erx_prog_fd_ioctl(int fd, unsigned long request, void *arg);

/*
 * munmap in a program (docs/design-programs.md#the-startup-message).  Its own
 * checks come first: a len of 0, a len that overflows when rounded up to
 * whole pages, an addr off a page boundary and an end, addr plus the rounded
 * len, past 2^64 are -EINVAL.  Then, while a descriptor holds the mem range,
 * a range inside it returns 0 and unmaps nothing, since the mapping is the
 * session's, and one that meets it any other way is -EINVAL; any other range
 * is released, 0, or -EINVAL when the release fails.
 */
int	erx_prog_fd_munmap(uint64_t addr, uint64_t len);
/*
 * Whether an mmap with MAP_FIXED of len bytes at addr may run: 0, or -EINVAL
 * when the range meets the held mem range or its end passes 2^64, so the
 * descriptor's mmap never returns an address that holds something else.
 */
int	erx_prog_fd_fixed_check(uint64_t addr, uint64_t len);

/*
 * The executor's: the end a report or a doorbell's label names by pipe and
 * end number, locked with erx_pipe_end_lock, or NULL when the program holds
 * no such end.  The caller unlocks it with erx_pipe_end_unlock.
 */
struct erx_pipe_end	*erx_prog_fd_find_end(uint32_t pipe, uint32_t end);
/* The executor's: calls fn on each end the program holds, each under its lock. */
void	erx_prog_fd_each_end(void (*fn)(struct erx_pipe_end *));

#endif /* !LIBERX_PROGRAM_FD_H */
