/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A program's descriptor table (fd.h).  The slots, every object's refs and
 * the list of live objects are table_lock's.  A pipe end, the one kind a
 * report names, is linked into the list with its first reference and
 * unlinked with its last, under the lock, so the executor finds only ends
 * some slot or call still holds; null, a mem range and a file never join it.  The
 * object's own release runs after the lock is let go: a pipe end's waits
 * out an executor that found it before the unlink by taking the end's lock
 * (pipe.c), and sends its notices without the table lock held.
 *
 * The lock order is the table's, then an end's: every taking of the table
 * lock goes through table_take, which stops a thread that holds an end's
 * lock, so a wrong order fails at once in every build instead of
 * deadlocking under one schedule.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/fd.h"
#include "liberx/program/fd_plan.h"
#include "liberx/program/file.h"
#include "liberx/program/pages.h"
#include "liberx/program/pipe.h"
#include "liberx/program/signal.h"

static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;
static erx_prog_slot_t slots[ERX_PROG_FDS_MAX];
static erx_prog_obj_t *live;

/*
 * An open of /dev/null, one for each null descriptor of the startup
 * message and shared by its dups: reads end the stream, writes take every
 * byte, and offset, table_lock's, moves only by lseek, as FreeBSD's
 * /dev/null keeps the offset of each open.  It owns nothing but itself and
 * never joins the live list.
 */
typedef struct erx_prog_null {
	erx_prog_obj_t	 obj;		/* first, so a head is its object */
	int64_t		 offset;
} erx_prog_null_t;

static erx_prog_null_t *
null_of(erx_prog_obj_t *obj)
{
	return ((erx_prog_null_t *)obj);
}

/*
 * A mem range of the startup message: bytes of memory at address that the
 * session mapped read-write into the program while it built it.  The
 * program holds no capability to it, so the object owns nothing but itself:
 * closing its last descriptor leaves the mapping, as closing a file's does.
 * No report names it, so it never joins the live list.
 */
typedef struct erx_prog_mem {
	erx_prog_obj_t	 obj;		/* first, so a head is its object */
	uintptr_t	 address;
	size_t		 bytes;
} erx_prog_mem_t;

static erx_prog_mem_t *
mem_of(erx_prog_obj_t *obj)
{
	return ((erx_prog_mem_t *)obj);
}

/*
 * The program's one mem range while some slot or call holds it, else NULL: table_lock's.
 * The startup plan accepts at most one mem descriptor (startup.c), so one pointer is the
 * whole of what munmap and a fixed mmap are checked against.
 */
static erx_prog_mem_t *mem_held;

/* Takes table_lock; a thread that holds an end's lock has broken the lock order and stops. */
static void
table_take(void)
{
	if (erx_pipe_end_held())
		__builtin_trap();
	(void)pthread_mutex_lock(&table_lock);
}

/* Takes a reference; the first links the object into the live list.  The caller holds table_lock. */
static void
obj_hold(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		obj->refs++;
		return;
	case ERX_PROG_OBJ_PIPE:
		if (obj->refs++ == 0) {
			obj->prev = NULL;
			obj->next = live;
			if (live != NULL)
				live->prev = obj;
			live = obj;
		}
		return;
	case ERX_PROG_OBJ_MEM:
		if (obj->refs++ == 0)
			mem_held = mem_of(obj);
		return;
	case ERX_PROG_OBJ_FILE:
		obj->refs++;
		return;
	}
}

/*
 * Drops a reference; true when it was the last, and the object then is out
 * of the live list and the caller's to let go.  The caller holds table_lock.
 */
static bool
obj_drop(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_FILE:
		return (--obj->refs == 0);
	case ERX_PROG_OBJ_PIPE:
		if (--obj->refs != 0)
			return (false);
		if (obj->prev != NULL)
			obj->prev->next = obj->next;
		else
			live = obj->next;
		if (obj->next != NULL)
			obj->next->prev = obj->prev;
		obj->prev = obj->next = NULL;
		return (true);
	case ERX_PROG_OBJ_MEM:
		if (--obj->refs != 0)
			return (false);
		mem_held = NULL;
		return (true);
	}
	return (false);
}

/* Lets go of an object whose last reference went; no lock held. */
static void
obj_release(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		erx_prog_pages_give(obj, sizeof(erx_prog_null_t));
		return;
	case ERX_PROG_OBJ_PIPE:
		erx_pipe_release(erx_pipe_end_of(obj));
		return;
	case ERX_PROG_OBJ_MEM:
		erx_prog_pages_give(obj, sizeof(erx_prog_mem_t));
		return;
	case ERX_PROG_OBJ_FILE:
		erx_prog_file_release(erx_prog_file_of(obj));
		return;
	}
}

static bool
fd_valid(int fd)
{
	return (fd >= 0 && (uint32_t)fd < ERX_PROG_FDS_MAX);
}

/* Puts obj, with a new reference, into the empty slot fd; false when fd is taken or out of range. */
static bool
fd_install(int fd, erx_prog_obj_t *obj)
{
	bool ok;

	table_take();
	ok = fd_valid(fd) && slots[fd].obj == NULL;
	if (ok) {
		obj_hold(obj);
		slots[fd] = (erx_prog_slot_t){ .obj = obj };
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (ok);
}

/*
 * A mem object for the range of pages the descriptor names.  The check holds
 * the first page and the count to u32 from 1, so the range lies within
 * 2^45 bytes; the arithmetic is checked all the same, and the size must fit
 * fstat's off_t.
 */
static int
mem_open(const erx_prog_descriptor_t *descriptor, erx_prog_mem_t **out)
{
	const uint64_t page = descriptor->u.mem.mem_page;
	const uint64_t pages = descriptor->u.mem.mem_pages;
	uint64_t address, bytes, end;
	erx_prog_mem_t *mem;

	if (__builtin_mul_overflow(page, (uint64_t)ERX_PAGE_SIZE, &address) ||
	    __builtin_mul_overflow(pages, (uint64_t)ERX_PAGE_SIZE, &bytes) ||
	    __builtin_add_overflow(address, bytes, &end))
		return (ERX_EINVAL);
	if (end > UINTPTR_MAX || bytes > (uint64_t)INT64_MAX)
		return (ERX_EINVAL);
	if ((mem = erx_prog_pages_take(sizeof(*mem))) == NULL)
		return (ERX_ENOMEM);
	*mem = (erx_prog_mem_t){
		.obj = { .kind = ERX_PROG_OBJ_MEM },
		.address = (uintptr_t)address,
		.bytes = (size_t)bytes,
	};
	*out = mem;
	return (ERX_OK);
}

/* One descriptor of the startup message into slot fd. */
static int
fd_setup_one(const erx_prog_fd_entry_t *entry)
{
	erx_pipe_end_t *end;
	erx_prog_mem_t *mem;
	erx_prog_null_t *null;
	int status;

	switch (entry->descriptor.which) {
	case ERX_PROG_DESCRIPTOR_MEM:
		if ((status = mem_open(&entry->descriptor, &mem)) != ERX_OK)
			return (status);
		if (fd_install(entry->fd, &mem->obj))
			return (ERX_OK);
		erx_prog_pages_give(mem, sizeof(*mem));
		return (ERX_EINVAL);
	case ERX_PROG_DESCRIPTOR_NULL:
		if ((null = erx_prog_pages_take(sizeof(*null))) == NULL)
			return (ERX_ENOMEM);
		*null = (erx_prog_null_t){ .obj = { .kind = ERX_PROG_OBJ_NULL } };
		if (fd_install(entry->fd, &null->obj))
			return (ERX_OK);
		erx_prog_pages_give(null, sizeof(*null));
		return (ERX_EINVAL);
	case ERX_PROG_DESCRIPTOR_PIPE_WRITE:
	case ERX_PROG_DESCRIPTOR_PIPE_READ:
		status = erx_pipe_open(&entry->descriptor, &end);
		if (status != ERX_OK)
			return (status);
		/*
		 * The check's fds are strictly ascending and below the table's size, so the
		 * slot is empty.  Were it not, the program stops and the end goes with its
		 * space: a release here would send {closed} from the executor, which may not
		 * wait for room.
		 */
		return (fd_install(entry->fd, &end->obj) ? ERX_OK : ERX_EINVAL);
	}
	/* The plan refused every other descriptor (startup.c). */
	return (ERX_EINVAL);
}

int
erx_prog_fd_setup(erx_prog_fds_iter_t fds)
{
	erx_prog_fd_entry_t entry;
	int status;

	while (erx_prog_fds_next(&fds, &entry))
		if ((status = fd_setup_one(&entry)) != ERX_OK)
			return (status);
	return (ERX_OK);
}

erx_prog_obj_t *
erx_prog_fd_get(int fd)
{
	erx_prog_obj_t *obj = NULL;

	table_take();
	if (fd_valid(fd) && (obj = slots[fd].obj) != NULL)
		obj_hold(obj);
	(void)pthread_mutex_unlock(&table_lock);
	return (obj);
}

void
erx_prog_obj_put(erx_prog_obj_t *obj)
{
	bool last;

	table_take();
	last = obj_drop(obj);
	(void)pthread_mutex_unlock(&table_lock);
	if (last)
		obj_release(obj);
}

/*
 * Applies the dup erx_prog_dup_plan answers for req.  What the slot held
 * is let go after the lock, as close lets it go.
 */
static int
fd_dup(erx_prog_dup_t req)
{
	erx_prog_obj_t *closed = NULL;
	bool last = false;
	int at;

	table_take();
	at = erx_prog_dup_plan(slots, ERX_PROG_FDS_MAX, req);
	if (at >= 0) {
		obj_hold(slots[req.from].obj);
		if ((closed = slots[at].obj) != NULL)
			last = obj_drop(closed);
		slots[at] = (erx_prog_slot_t){ .obj = slots[req.from].obj, .cloexec = req.cloexec };
	}
	(void)pthread_mutex_unlock(&table_lock);
	if (last)
		obj_release(closed);
	return (at);
}

int
erx_prog_fd_dup(int from)
{
	return (fd_dup((erx_prog_dup_t){ .mode = ERX_PROG_DUP_LOWEST, .from = from, .at = 0 }));
}

int
erx_prog_fd_dup3(int from, int to, int flags)
{
	erx_prog_dup_t req;
	const int status = erx_prog_dup3_req(from, to, flags, &req);

	if (status != 0)
		return (status);
	return (fd_dup(req));
}

int
erx_prog_fd_install_pair(erx_prog_obj_t *const objs[2], bool cloexec, int fds[2])
{
	int result;

	table_take();
	result = erx_prog_pair_plan(slots, ERX_PROG_FDS_MAX, fds);
	if (result == 0) {
		for (int at = 0; at < 2; at++) {
			obj_hold(objs[at]);
			slots[fds[at]] = (erx_prog_slot_t){ .obj = objs[at], .cloexec = cloexec };
		}
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (result);
}

int
erx_prog_fd_reserve(void)
{
	int result;

	table_take();
	if ((result = erx_prog_reserve_plan(slots, ERX_PROG_FDS_MAX)) >= 0)
		slots[result] = (erx_prog_slot_t){ .obj = NULL, .reserved = true };
	(void)pthread_mutex_unlock(&table_lock);
	return (result);
}

/* Whether slot fd is reserved.  The caller holds table_lock. */
static bool
slot_reserved(int fd)
{
	return (fd_valid(fd) && slots[fd].reserved);
}

void
erx_prog_fd_fill(int fd, erx_prog_obj_t *obj, bool cloexec)
{
	table_take();
	/* Only the open that reserved the slot fills it; anything else is a bug that must not clobber a slot. */
	if (!slot_reserved(fd))
		__builtin_trap();
	obj_hold(obj);
	slots[fd] = (erx_prog_slot_t){ .obj = obj, .cloexec = cloexec };
	(void)pthread_mutex_unlock(&table_lock);
}

void
erx_prog_fd_unreserve(int fd)
{
	table_take();
	if (!slot_reserved(fd))
		__builtin_trap();
	slots[fd] = (erx_prog_slot_t){ .obj = NULL };
	(void)pthread_mutex_unlock(&table_lock);
}

int
erx_prog_fd_close(int fd)
{
	erx_prog_obj_t *obj = NULL;
	bool last = false;

	table_take();
	if (fd_valid(fd) && (obj = slots[fd].obj) != NULL) {
		slots[fd] = (erx_prog_slot_t){ .obj = NULL };
		last = obj_drop(obj);
	}
	(void)pthread_mutex_unlock(&table_lock);
	if (obj == NULL)
		return (-EBADF);
	if (last)
		obj_release(obj);
	return (0);
}

ssize_t
erx_prog_fd_read(int fd, void *buf, size_t len)
{
	erx_prog_obj_t *obj;
	ssize_t result = 0;

	if (len > SSIZE_MAX)
		return (-EINVAL);
	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		break;
	case ERX_PROG_OBJ_PIPE:
		result = erx_pipe_read(erx_pipe_end_of(obj), buf, len);
		break;
	case ERX_PROG_OBJ_MEM:
		result = -ESPIPE;
		break;
	case ERX_PROG_OBJ_FILE:
		result = len == 0 ? 0 : erx_prog_file_read(erx_prog_file_of(obj), buf, len);
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

/* A write of len bytes to obj, which the caller holds a counted reference to: the count or a negative errno. */
static ssize_t
obj_write(erx_prog_obj_t *obj, const void *buf, size_t len)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		return ((ssize_t)len);
	case ERX_PROG_OBJ_PIPE:
		return (erx_pipe_write(erx_pipe_end_of(obj), buf, len));
	case ERX_PROG_OBJ_MEM:
		return (-ESPIPE);
	case ERX_PROG_OBJ_FILE:
		return (len == 0 ? 0 : erx_prog_file_write(erx_prog_file_of(obj), buf, len));
	}
	return (-ESPIPE);
}

/* A write call's answer: EPIPE raises SIGPIPE for the writing thread before the write returns (design-pipes.md, "Writing"). */
static ssize_t
write_answer(ssize_t result)
{
	if (result == -EPIPE)
		erx_prog_sig_raise(ERX_SIGPIPE);
	return (result);
}

ssize_t
erx_prog_fd_write(int fd, const void *buf, size_t len)
{
	erx_prog_obj_t *obj;
	ssize_t result;

	if (len > SSIZE_MAX)
		return (-EINVAL);
	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	result = obj_write(obj, buf, len);
	erx_prog_obj_put(obj);
	return (write_answer(result));
}

/* Whether a vector's count and lengths may move: its byte count in *sum, or -EINVAL. */
static int
vector_check(const struct iovec *iov, int count, size_t *sum)
{
	*sum = 0;
	if (count < 0 || count > IOV_MAX)
		return (-EINVAL);
	for (int at = 0; at < count; at++) {
		if (__builtin_add_overflow(*sum, iov[at].iov_len, sum) || *sum > SSIZE_MAX)
			return (-EINVAL);
	}
	return (0);
}

void
erx_prog_fd_snapshot(erx_prog_slot_t table[ERX_PROG_FDS_MAX])
{
	table_take();
	for (uint32_t fd = 0; fd < ERX_PROG_FDS_MAX; fd++) {
		if (slots[fd].obj != NULL)
			obj_hold(slots[fd].obj);
		table[fd] = slots[fd];
	}
	(void)pthread_mutex_unlock(&table_lock);
}

long
erx_prog_fd_held_or(int fd, long what)
{
	erx_prog_obj_t *const obj = erx_prog_fd_get(fd);

	if (obj == NULL)
		return (-EBADF);
	erx_prog_obj_put(obj);
	return (what);
}

/* The first entry of a length above 0 is the one read: its bytes, the end of the stream or its error answer. */
ssize_t
erx_prog_fd_readv(int fd, const struct iovec *iov, int count)
{
	size_t sum;
	int status;

	if ((status = vector_check(iov, count, &sum)) != 0)
		return (status);
	for (int at = 0; at < count; at++) {
		if (iov[at].iov_len != 0)
			return (erx_prog_fd_read(fd, iov[at].iov_base, iov[at].iov_len));
	}
	return (erx_prog_fd_held_or(fd, 0));
}

/*
 * The entries gathered into buf, which holds ERX_PIPE_BUF bytes: each length is
 * loaded once and bounded by the room left, so a length another thread
 * changes after vector_check never writes past buf.  The bytes gathered.
 */
static size_t
vector_gather(const struct iovec *iov, int count, unsigned char *buf)
{
	size_t used = 0;

	for (int at = 0; at < count; at++) {
		const size_t room = ERX_PIPE_BUF - used;
		const size_t len = iov[at].iov_len < room ? iov[at].iov_len : room;

		if (len != 0)
			memcpy(buf + used, iov[at].iov_base, len);
		used += len;
	}
	return (used);
}

/*
 * The entries written one at a time to obj, until a short write: the bytes
 * written, or the error that ended the call, as erx_pipe_write answers
 * across its waits, EAGAIN after bytes went being their count.
 */
static ssize_t
vector_write(erx_prog_obj_t *obj, const struct iovec *iov, int count)
{
	ssize_t total = 0;

	for (int at = 0; at < count; at++) {
		const size_t len = iov[at].iov_len;
		const ssize_t put = obj_write(obj, iov[at].iov_base, len);

		if (put == -EAGAIN && total > 0)
			break;
		if (put < 0)
			return (put);
		total += put;
		if ((size_t)put < len)
			break;
	}
	return (total);
}

ssize_t
erx_prog_fd_writev(int fd, const struct iovec *iov, int count)
{
	unsigned char gathered[ERX_PIPE_BUF];
	erx_prog_obj_t *obj;
	ssize_t result;
	size_t sum;
	int status;

	if ((status = vector_check(iov, count, &sum)) != 0)
		return (status);
	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	if (sum <= sizeof(gathered))
		result = obj_write(obj, gathered, vector_gather(iov, count, gathered));
	else
		result = vector_write(obj, iov, count);
	erx_prog_obj_put(obj);
	return (write_answer(result));
}

/* Whether a mmap of mem may return its mapping: the one way design-programs.md gives. */
static int
mem_map_check(const erx_prog_mem_t *mem, size_t len, int prot, int flags, off_t offset)
{
	if (flags != MAP_SHARED || offset != 0 || len == 0 || len > mem->bytes)
		return (-EINVAL);
	if ((prot & ~(PROT_READ | PROT_WRITE)) != 0)
		return (-EACCES);
	return (0);
}

int
erx_prog_fd_mmap(int fd, size_t len, int prot, int flags, off_t offset, void **addr)
{
	erx_prog_obj_t *obj;
	int result = -ENODEV;

	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_PIPE:
	case ERX_PROG_OBJ_FILE:
		break;
	case ERX_PROG_OBJ_MEM:
		result = mem_map_check(mem_of(obj), len, prot, flags, offset);
		if (result == 0)
			*addr = (void *)mem_of(obj)->address;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

int
erx_prog_fd_fstat(int fd, struct stat *st)
{
	erx_prog_obj_t *obj;
	int result = 0;

	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	memset(st, 0, sizeof(*st));
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		st->st_mode = S_IFCHR | 0666;
		break;
	case ERX_PROG_OBJ_PIPE:
		st->st_mode = S_IFIFO | 0600;
		break;
	case ERX_PROG_OBJ_MEM:
		st->st_mode = S_IFREG | 0600;
		st->st_size = (off_t)mem_of(obj)->bytes;
		break;
	case ERX_PROG_OBJ_FILE:
		result = -ENOSYS;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

off_t
erx_prog_fd_lseek(int fd, off_t offset, int whence)
{
	erx_prog_obj_t *obj;
	off_t result = -ESPIPE;
	int64_t to;

	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		table_take();
		result = erx_prog_seek_plan(null_of(obj)->offset, offset, whence, 0, &to);
		if (result == 0) {
			null_of(obj)->offset = to;
			result = to;
		}
		(void)pthread_mutex_unlock(&table_lock);
		break;
	case ERX_PROG_OBJ_PIPE:
	case ERX_PROG_OBJ_MEM:
		break;
	case ERX_PROG_OBJ_FILE:
		result = -ENOSYS;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

/* The slot fd's FD_CLOEXEC: FD_CLOEXEC or 0, or -EBADF for an empty slot. */
static int
slot_cloexec_get(int fd)
{
	int result = -EBADF;

	table_take();
	if (fd_valid(fd) && slots[fd].obj != NULL)
		result = slots[fd].cloexec ? FD_CLOEXEC : 0;
	(void)pthread_mutex_unlock(&table_lock);
	return (result);
}

/* Sets the slot fd's FD_CLOEXEC to cloexec: 0, or -EBADF for an empty slot. */
static int
slot_cloexec_set(int fd, bool cloexec)
{
	int result = -EBADF;

	table_take();
	if (fd_valid(fd) && slots[fd].obj != NULL) {
		slots[fd].cloexec = cloexec;
		result = 0;
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (result);
}

/*
 * The status flags obj's open fixes for its life: a file's O_APPEND, which
 * the handler took at the open and which no write request carries, so a
 * change of it would leave the writes doing what F_GETFL no longer says.
 */
static uint32_t
obj_status_fixed(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_MEM:
	case ERX_PROG_OBJ_PIPE:
		return (0);
	case ERX_PROG_OBJ_FILE:
		return (O_APPEND);
	}
	return (0);
}

/*
 * Replaces the bits of mask in the status flags of slot fd's open with those
 * of bits, under the table lock, which every change of them takes: 0, -EBADF
 * for an empty slot, or -EINVAL, changing nothing, when the change would
 * flip a flag the open fixes (obj_status_fixed).
 */
static int
status_change(int fd, uint32_t mask, uint32_t bits)
{
	int result = -EBADF;

	table_take();
	if (fd_valid(fd) && slots[fd].obj != NULL) {
		erx_prog_obj_t *const obj = slots[fd].obj;
		const uint32_t now = __atomic_load_n(&obj->status, __ATOMIC_RELAXED);
		const uint32_t next = (now & ~mask) | bits;

		result = ((now ^ next) & obj_status_fixed(obj)) != 0 ? -EINVAL : 0;
		if (result == 0)
			__atomic_store_n(&obj->status, next, __ATOMIC_RELAXED);
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (result);
}

/* The access mode of obj's open, which F_GETFL reads with its status flags. */
static long
obj_access(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_MEM:
		return (O_RDWR);
	case ERX_PROG_OBJ_PIPE:
		return (erx_pipe_end_of(obj)->kind == ERX_PIPE_READ ? O_RDONLY : O_WRONLY);
	case ERX_PROG_OBJ_FILE:
		return (erx_prog_file_of(obj)->access);
	}
	return (O_RDWR);
}

long
erx_prog_fd_fcntl(int fd, int cmd, long arg)
{
	erx_prog_fcntl_t req;
	erx_prog_obj_t *obj;
	uint32_t status;
	long result;

	if ((result = erx_prog_fcntl_req(fd, cmd, arg, &req)) != 0)
		return (result);
	switch (req.op) {
	case ERX_PROG_FCNTL_DUP:
		return (fd_dup(req.u.dup));
	case ERX_PROG_FCNTL_GETFD:
		return (slot_cloexec_get(fd));
	case ERX_PROG_FCNTL_SETFD:
		return (slot_cloexec_set(fd, req.u.cloexec));
	case ERX_PROG_FCNTL_GETFL:
		if ((obj = erx_prog_fd_get(fd)) == NULL)
			return (-EBADF);
		result = obj_access(obj) | (long)__atomic_load_n(&obj->status, __ATOMIC_RELAXED);
		erx_prog_obj_put(obj);
		return (result);
	case ERX_PROG_FCNTL_SETFL:
		/* An empty slot's EBADF comes before the change's own refusal, as in FreeBSD's kern_fcntl. */
		if ((result = erx_prog_status_set(req.u.status, &status)) != 0)
			return (erx_prog_fd_held_or(fd, result));
		return (status_change(fd, UINT32_MAX, status));
	}
	return (-EINVAL);
}

int
erx_prog_fd_ioctl(int fd, unsigned long request, void *arg)
{
	bool on;
	int refusal;

	switch (request) {
	case FIOCLEX:
		return (slot_cloexec_set(fd, true));
	case FIONCLEX:
		return (slot_cloexec_set(fd, false));
	case FIONBIO:
		on = *(const int *)arg != 0;
		return (status_change(fd, O_NONBLOCK, on ? O_NONBLOCK : 0));
	case FIOASYNC:
		on = *(const int *)arg != 0;
		refusal = erx_prog_async_set(on);
		return ((int)erx_prog_fd_held_or(fd, refusal));
	default:
		return ((int)erx_prog_fd_held_or(fd, -ENOTTY));
	}
}

/* Where [lo, end) lies against the held mem range; end is past lo, both checked. */
typedef enum { RANGE_APART, RANGE_INSIDE, RANGE_ACROSS } range_t;

static range_t
range_against_mem(uint64_t lo, uint64_t end)
{
	range_t where = RANGE_APART;

	table_take();
	if (mem_held != NULL) {
		const uint64_t mem_lo = mem_held->address;
		const uint64_t mem_end = mem_lo + mem_held->bytes;	/* mem_open checked the sum */

		if (lo >= mem_lo && end <= mem_end)
			where = RANGE_INSIDE;
		else if (lo < mem_end && end > mem_lo)
			where = RANGE_ACROSS;
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (where);
}

int
erx_prog_fd_munmap(uint64_t addr, uint64_t len)
{
	const uint64_t page_mask = (uint64_t)ERX_PAGE_SIZE - 1;
	uint64_t size, end;

	/* munmap's own checks, as for any munmap, before the range is compared. */
	if (len == 0 || len > UINT64_MAX - page_mask || (addr & page_mask) != 0)
		return (-EINVAL);
	size = (len + page_mask) & ~page_mask;
	if (__builtin_add_overflow(addr, size, &end))
		return (-EINVAL);
	switch (range_against_mem(addr, end)) {
	case RANGE_INSIDE:
		return (0);
	case RANGE_ACROSS:
		return (-EINVAL);
	case RANGE_APART:
		break;
	}
	return (erx_vm_release(ERX_CAP_SELF, addr, size) == ERX_OK ? 0 : -EINVAL);
}

int
erx_prog_fd_fixed_check(uint64_t addr, uint64_t len)
{
	uint64_t end;

	if (len == 0)
		return (0);
	if (__builtin_add_overflow(addr, len, &end))
		return (-EINVAL);
	return (range_against_mem(addr, end) == RANGE_APART ? 0 : -EINVAL);
}

erx_pipe_end_t *
erx_prog_fd_find_end(uint32_t pipe, uint32_t end)
{
	erx_pipe_end_t *found = NULL;

	table_take();
	for (erx_prog_obj_t *obj = live; obj != NULL && found == NULL; obj = obj->next) {
		switch (obj->kind) {
		case ERX_PROG_OBJ_NULL:
			break;
		case ERX_PROG_OBJ_PIPE:
			if (erx_pipe_end_of(obj)->pipe == pipe && erx_pipe_end_of(obj)->end == end)
				found = erx_pipe_end_of(obj);
			break;
		case ERX_PROG_OBJ_MEM:
		case ERX_PROG_OBJ_FILE:
			break;
		}
	}
	/* Locked before the table lets go: the end's last release waits for this lock. */
	if (found != NULL)
		erx_pipe_end_lock(found);
	(void)pthread_mutex_unlock(&table_lock);
	return (found);
}

void
erx_prog_fd_each_end(void (*fn)(erx_pipe_end_t *))
{
	table_take();
	for (erx_prog_obj_t *obj = live; obj != NULL; obj = obj->next) {
		switch (obj->kind) {
		case ERX_PROG_OBJ_NULL:
			break;
		case ERX_PROG_OBJ_PIPE:
			erx_pipe_end_lock(erx_pipe_end_of(obj));
			fn(erx_pipe_end_of(obj));
			erx_pipe_end_unlock(erx_pipe_end_of(obj));
			break;
		case ERX_PROG_OBJ_MEM:
		case ERX_PROG_OBJ_FILE:
			break;
		}
	}
	(void)pthread_mutex_unlock(&table_lock);
}
