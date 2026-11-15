/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of test/host/prog_file_test.rb: liberx's file client
 * (liberx/program/file.c), the descriptor table (fd.c) and the data area
 * (data.c) over a stand-in channel.  The stand-in plays the program's
 * handler: it frames each request as the channel does, checks it with the
 * profile's generated request check, so a value the file client writes
 * wrong fails the case, and serves it from a small file system in memory,
 * copying read and write bytes through the data area as the session's
 * handler does.  Every request served is logged, so a case sees what was
 * sent.  The backend is faked over host memory; pipes and signals are not
 * linked, and reaching them fails the case.
 *
 * It reads one command a line from the file its argument names and prints
 * one answer a line.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/etf.h"
#include "erx/prog_profile.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"
#include "liberx/program/fd.h"
#include "liberx/program/file.h"
#include "liberx/program/pipe.h"
#include "liberx/program/program.h"

static _Noreturn void
fail(const char *why)
{
	printf("FAIL %s\n", why);
	fflush(stdout);
	_exit(1);
}

/* ---------------------------------------------------------------------
 * The backend, over host memory */

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	void *run;

	(void)space;
	(void)addr;
	(void)flags;
	run = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (run == MAP_FAILED)
		return (ERX_ENOMEM);
	*reserved = (uint64_t)(uintptr_t)run;
	return (ERX_OK);
}

int
erx_vm_commit(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	(void)addr;
	(void)size;
	return (ERX_OK);
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	return (munmap((void *)(uintptr_t)addr, (size_t)size) == 0 ? ERX_OK : ERX_EINVAL);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	(void)space;
	(void)addr;
	(void)size;
	(void)mem;
	(void)offset;
	(void)prot;
	fail("no memory object is mapped");
}

static pthread_mutex_t futex_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t futex_cond = PTHREAD_COND_INITIALIZER;

int
erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline)
{
	_Atomic uint32_t *const word = (_Atomic uint32_t *)(uintptr_t)addr;

	if (deadline != ERX_WAIT_FOREVER)
		fail("a data slot's wait has no deadline");
	pthread_mutex_lock(&futex_lock);
	while (atomic_load(word) == expected)
		pthread_cond_wait(&futex_cond, &futex_lock);
	pthread_mutex_unlock(&futex_lock);
	return (ERX_OK);
}

int
erx_umtx_wake(uint64_t addr, uint32_t count)
{
	(void)addr;
	(void)count;
	pthread_mutex_lock(&futex_lock);
	pthread_cond_broadcast(&futex_cond);
	pthread_mutex_unlock(&futex_lock);
	return (ERX_OK);
}

/* No case makes a pipe or raises a signal. */
bool
erx_pipe_end_held(void)
{
	return (false);
}

void
erx_pipe_end_lock(erx_pipe_end_t *end)
{
	(void)end;
	fail("a pipe end");
}

void
erx_pipe_end_unlock(erx_pipe_end_t *end)
{
	(void)end;
	fail("a pipe end");
}

int
erx_pipe_open(const erx_prog_descriptor_t *d, erx_pipe_end_t **out)
{
	(void)d;
	(void)out;
	fail("a pipe end");
}

ssize_t
erx_pipe_read(erx_pipe_end_t *end, void *buf, size_t len)
{
	(void)end;
	(void)buf;
	(void)len;
	fail("a pipe end");
}

ssize_t
erx_pipe_write(erx_pipe_end_t *end, const void *buf, size_t len)
{
	(void)end;
	(void)buf;
	(void)len;
	fail("a pipe end");
}

void
erx_pipe_release(erx_pipe_end_t *end)
{
	(void)end;
	fail("a pipe end");
}

void
erx_prog_sig_raise(int signo)
{
	(void)signo;
	fail("a signal");
}

/* The program's start: its umask and its data area of slots slots, which "slots" sets. */
static erx_prog_self_t self = { .umask = 022 };

const erx_prog_self_t *
erx_prog_self(void)
{
	return (&self);
}

static void
area_make(uint32_t slots)
{
	if (self.data_area != NULL)
		fail("the data area is made once");
	self.data_bytes = (size_t)slots * ERX_PROG_DATA_SLOT_BYTES;
	self.data_area = malloc(self.data_bytes);
	if (self.data_area == NULL)
		fail("no memory for the data area");
}

/* ---------------------------------------------------------------------
 * The stand-in handler */

#define FILES		4
#define FILE_BYTES	(4 * 65536)
#define OPENS		ERX_PROG_FDS_MAX

static pthread_mutex_t handler_lock = PTHREAD_MUTEX_INITIALIZER;
static struct file {
	char		 name[64];	/* "" for none */
	uint16_t	 mode;
	size_t		 size;
	uint8_t		 bytes[FILE_BYTES];
} files[FILES];
static struct open {
	struct file	*file;		/* NULL for a free open number */
	uint32_t	 flags;
	size_t		 offset;
} opens[OPENS];
static char log_text[8192];
static int fail_next;		/* the errno the next request answers, or 0 */
static uint32_t lie_next;	/* bytes the next read answers past its count */
static uint32_t slow;		/* microseconds a read waits after it fills its slot */
static int probe = -1;		/* the descriptor the next open's request tries, or -1 */

static void
log_line(const char *line)
{
	if (strlen(log_text) + strlen(line) + 2 > sizeof(log_text))
		fail("the log is full");
	strcat(log_text, " ");
	strcat(log_text, line);
}

static struct file *
file_find(const erx_profile_text_t *path)
{
	for (int at = 0; at < FILES; at++)
		if (files[at].name[0] != '\0' && strlen(files[at].name) == path->len &&
		    memcmp(files[at].name, path->bytes, path->len) == 0)
			return (&files[at]);
	return (NULL);
}

static struct file *
file_make(const erx_profile_text_t *path, uint16_t mode)
{
	for (int at = 0; at < FILES; at++) {
		if (files[at].name[0] == '\0') {
			if (path->len >= sizeof(files[at].name))
				fail("a name too long for the stand-in");
			memcpy(files[at].name, path->bytes, path->len);
			files[at].name[path->len] = '\0';
			files[at].mode = mode;
			files[at].size = 0;
			return (&files[at]);
		}
	}
	fail("no room for a file");
}

/* An open's answer: the lowest open number free, as the handler gives it. */
static void
opened(erx_prog_open_reply_t *r, struct file *f, uint32_t flags)
{
	for (uint16_t at = 0; at < OPENS; at++) {
		if (opens[at].file == NULL) {
			opens[at] = (struct open){ .file = f, .flags = flags };
			if ((flags & ERX_P9_O_TRUNC) != 0)
				f->size = 0;
			r->which = ERX_PROG_OPEN_REPLY_OK;
			r->u.ok.open = at;
			return;
		}
	}
	r->which = ERX_PROG_OPEN_REPLY_ERROR;
	r->u.error.errnum = EMFILE;
}

static void
open_error(erx_prog_open_reply_t *r, int errnum)
{
	r->which = ERX_PROG_OPEN_REPLY_ERROR;
	r->u.error.errnum = errnum;
}

static struct open *
open_find(uint16_t open)
{
	if (open >= OPENS || opens[open].file == NULL)
		fail("a request names an open the program does not own");
	return (&opens[open]);
}

static uint8_t *
slot_bytes(uint8_t slot)
{
	if ((size_t)(slot + 1) * ERX_PROG_DATA_SLOT_BYTES > self.data_bytes)
		fail("a data slot past the program's slots");
	return ((uint8_t *)self.data_area + (size_t)slot * ERX_PROG_DATA_SLOT_BYTES);
}

static void
serve_read(const erx_prog_request_t *q, erx_prog_io_reply_t *r)
{
	struct open *const o = open_find(q->u.file_read.open);
	const size_t left = o->file->size > o->offset ? o->file->size - o->offset : 0;
	const size_t n = left < q->u.file_read.io_count ? left : q->u.file_read.io_count;
	char line[64];

	memcpy(slot_bytes(q->u.file_read.data_slot), o->file->bytes + o->offset, n);
	o->offset += n;
	snprintf(line, sizeof(line), "read:%u:%u:%u", q->u.file_read.open, q->u.file_read.io_count,
	    q->u.file_read.data_slot);
	log_line(line);
	r->which = ERX_PROG_IO_REPLY_OK;
	r->u.ok.io_done = (uint32_t)n + lie_next;
	lie_next = 0;
}

static void
serve_write(const erx_prog_request_t *q, erx_prog_io_reply_t *r)
{
	struct open *const o = open_find(q->u.file_write.open);
	const uint32_t n = q->u.file_write.io_count;
	char line[64];

	if ((o->flags & ERX_P9_O_APPEND) != 0)
		o->offset = o->file->size;
	if (o->offset + n > FILE_BYTES)
		fail("a write past the stand-in's file");
	memcpy(o->file->bytes + o->offset, slot_bytes(q->u.file_write.data_slot), n);
	o->offset += n;
	if (o->offset > o->file->size)
		o->file->size = o->offset;
	snprintf(line, sizeof(line), "write:%u:%u:%u", q->u.file_write.open, n, q->u.file_write.data_slot);
	log_line(line);
	r->which = ERX_PROG_IO_REPLY_OK;
	r->u.ok.io_done = n;
}

/* The handler's answer to request q, into *reply. */
static void
serve(const erx_prog_request_t *q, erx_prog_reply_t *reply)
{
	char line[ERX_PROG_PATH_MAX + 64];

	switch (q->which) {
	case ERX_PROG_REQUEST_FILE_LOPEN: {
		struct file *const f = file_find(&q->u.file_lopen.file_path);

		snprintf(line, sizeof(line), "lopen:%.*s:%#x", (int)q->u.file_lopen.file_path.len,
		    (const char *)q->u.file_lopen.file_path.bytes, q->u.file_lopen.open_flags);
		log_line(line);
		if (fail_next != 0)
			open_error(&reply->u.file_lopen, fail_next);
		else if (f == NULL)
			open_error(&reply->u.file_lopen, ENOENT);
		else
			opened(&reply->u.file_lopen, f, q->u.file_lopen.open_flags);
		break;
	}
	case ERX_PROG_REQUEST_FILE_LCREATE: {
		struct file *f = file_find(&q->u.file_lcreate.file_path);

		snprintf(line, sizeof(line), "lcreate:%.*s:%#x:%#o", (int)q->u.file_lcreate.file_path.len,
		    (const char *)q->u.file_lcreate.file_path.bytes, q->u.file_lcreate.open_flags,
		    q->u.file_lcreate.file_mode);
		log_line(line);
		if (fail_next != 0) {
			open_error(&reply->u.file_lcreate, fail_next);
		} else if (f != NULL && (q->u.file_lcreate.open_flags & ERX_P9_O_EXCL) != 0) {
			open_error(&reply->u.file_lcreate, EEXIST);
		} else {
			if (f == NULL)
				f = file_make(&q->u.file_lcreate.file_path, q->u.file_lcreate.file_mode);
			opened(&reply->u.file_lcreate, f, q->u.file_lcreate.open_flags);
		}
		break;
	}
	case ERX_PROG_REQUEST_FILE_READ:
		if (fail_next != 0) {
			reply->u.file_read = (erx_prog_io_reply_t){ .which = ERX_PROG_IO_REPLY_ERROR,
			    .u.error.errnum = fail_next };
			break;
		}
		serve_read(q, &reply->u.file_read);
		break;
	case ERX_PROG_REQUEST_FILE_WRITE:
		if (fail_next != 0) {
			reply->u.file_write = (erx_prog_io_reply_t){ .which = ERX_PROG_IO_REPLY_ERROR,
			    .u.error.errnum = fail_next };
			break;
		}
		serve_write(q, &reply->u.file_write);
		break;
	case ERX_PROG_REQUEST_FILE_CLUNK:
		open_find(q->u.file_clunk.open)->file = NULL;
		snprintf(line, sizeof(line), "clunk:%u", q->u.file_clunk.open);
		log_line(line);
		reply->u.file_clunk.which = ERX_PROG_CLUNK_REPLY_OK;
		break;
	default:
		fail("a request that is no file request");
	}
	fail_next = 0;
}

/*
 * The stand-in channel: frames the request as channel.c does, with the
 * value's version byte giving way to the envelope's, checks it with the
 * generated request check, and runs fn on its answer.
 */
int
erx_prog_channel_request(uint16_t request, const uint8_t *value, size_t len, erx_prog_reply_fn_t *fn, void *arg)
{
	erx_prog_reply_t reply;
	static uint8_t scratch[262144];
	uint8_t frame[ERX_PROG_PATH_MAX + 128];
	erx_profile_refusal_t refusal;
	erx_prog_request_t q;
	erx_etf_writer_t w;
	size_t head;
	uint8_t slot;

	erx_etf_writer_init(&w, frame, sizeof(frame));
	erx_etf_put_tuple(&w, 4);
	erx_etf_put_atom(&w, "erx_prog", strlen("erx_prog"));
	erx_etf_put_integer(&w, (int64_t)erx_prog_profile.version);
	erx_etf_put_integer(&w, 0);
	if (!erx_etf_writer_done(&w, &head) || len < 1 || head + len - 1 > sizeof(frame))
		fail("a request too large for the stand-in");
	memcpy(frame + head, value + 1, len - 1);
	pthread_mutex_lock(&handler_lock);
	if (erx_prog_scratch_bytes(head + len - 1) > sizeof(scratch) ||
	    !erx_prog_check_request(frame, head + len - 1, scratch, sizeof(scratch), &slot, &q, &refusal)) {
		printf("refused: reason %d at %zu\n", (int)refusal.reason, refusal.offset);
		fail("a request the profile refuses");
	}
	if (q.which != request)
		fail("a request of another case than the one named");
	/* While an open waits for its reply, its slot is reserved: every call on it finds nothing. */
	if (probe >= 0 && (q.which == ERX_PROG_REQUEST_FILE_LOPEN || q.which == ERX_PROG_REQUEST_FILE_LCREATE)) {
		erx_prog_obj_t *const got = erx_prog_fd_get(probe);
		char line[64];

		/* A dup of 0 meanwhile takes the lowest slot the open has not reserved; a dup3 onto it is EBUSY. */
		snprintf(line, sizeof(line), "probe:%d:%d:%s:%d:%d", erx_prog_fd_close(probe), erx_prog_fd_dup(probe),
		    got == NULL ? "none" : "object", erx_prog_fd_dup(0), erx_prog_fd_dup3(0, probe, 0));
		log_line(line);
		if (got != NULL)
			erx_prog_obj_put(got);
		probe = -1;
	}
	serve(&q, &reply);
	pthread_mutex_unlock(&handler_lock);
	/* A slow read keeps its slot a while, so a slot two threads shared would be overwritten. */
	if (q.which == ERX_PROG_REQUEST_FILE_READ && slow != 0)
		usleep(slow);
	fn(&reply, arg);
	return (ERX_OK);
}

/* ---------------------------------------------------------------------
 * Commands */

/* Open flags by name, the host's own values, so a case reads the same on every host. */
static int
flags_of(const char *names)
{
	static const struct { const char *name; int flag; } table[] = {
		{ "rdonly", O_RDONLY }, { "wronly", O_WRONLY }, { "rdwr", O_RDWR }, { "creat", O_CREAT },
		{ "excl", O_EXCL }, { "trunc", O_TRUNC }, { "append", O_APPEND }, { "sync", O_SYNC },
		{ "dsync", O_DSYNC }, { "cloexec", O_CLOEXEC }, { "noctty", O_NOCTTY },
		{ "directory", O_DIRECTORY }, { "nofollow", O_NOFOLLOW }, { "nonblock", O_NONBLOCK },
		{ "accmode", O_WRONLY | O_RDWR },
	};
	char copy[256], *word, *rest;
	int flags = 0;

	snprintf(copy, sizeof(copy), "%s", names);
	for (rest = copy; (word = strsep(&rest, "|")) != NULL;) {
		size_t at;

		for (at = 0; at < sizeof(table) / sizeof(table[0]) && strcmp(table[at].name, word) != 0; at++)
			continue;
		if (at == sizeof(table) / sizeof(table[0]))
			fail(word);
		flags |= table[at].flag;
	}
	return (flags);
}

/* The byte at offset of the pattern seed writes: distinct for each seed and offset. */
static uint8_t
pattern(unsigned seed, size_t offset)
{
	return ((uint8_t)(seed * 131 + offset * 7 + offset / 251));
}

/* Writes n bytes of seed's pattern from offset 0: the write's answer. */
static ssize_t
write_pattern(int fd, unsigned seed, size_t n)
{
	uint8_t *const buf = malloc(n);
	ssize_t wrote;

	for (size_t at = 0; at < n; at++)
		buf[at] = pattern(seed, at);
	wrote = erx_prog_fd_write(fd, buf, n);
	free(buf);
	return (wrote);
}

/* Reads n bytes and answers the count and whether they are seed's pattern from offset 0. */
static bool
read_check(int fd, unsigned seed, size_t n, ssize_t *got)
{
	uint8_t *const buf = malloc(n);
	bool same = true;

	*got = erx_prog_fd_read(fd, buf, n);
	for (ssize_t at = 0; at < *got; at++)
		same = same && buf[at] == pattern(seed, (size_t)at);
	free(buf);
	return (same);
}

static void
do_readn(int fd, unsigned seed, size_t n)
{
	ssize_t got;
	const bool same = read_check(fd, seed, n, &got);

	printf("%zd %s\n", got, same ? "same" : "differs");
}

/* Two threads, each reading its own file whole rounds times through one data area. */
typedef struct racer {
	const char	*path;
	unsigned	 seed;
	size_t		 size;
	unsigned	 rounds;
	bool		 ok;
} racer_t;

static void *
racer_main(void *arg)
{
	racer_t *const r = arg;

	r->ok = true;
	for (unsigned round = 0; round < r->rounds && r->ok; round++) {
		const int fd = erx_prog_file_openat(AT_FDCWD, r->path, O_RDONLY, 0);
		ssize_t got;

		r->ok = fd >= 0 && read_check(fd, r->seed, r->size, &got) && got == (ssize_t)r->size &&
		    erx_prog_fd_close(fd) == 0;
	}
	return (NULL);
}

static void
do_race(unsigned rounds, size_t size)
{
	racer_t racers[2] = {
		{ .path = "/race/a", .seed = 1, .size = size, .rounds = rounds },
		{ .path = "/race/b", .seed = 2, .size = size, .rounds = rounds },
	};
	pthread_t threads[2];

	for (int at = 0; at < 2; at++) {
		const int fd = erx_prog_file_openat(AT_FDCWD, racers[at].path, O_WRONLY | O_CREAT, 0644);

		if (fd < 0 || write_pattern(fd, racers[at].seed, size) != (ssize_t)size)
			fail("the race's file");
		(void)erx_prog_fd_close(fd);
	}
	for (int at = 0; at < 2; at++)
		pthread_create(&threads[at], NULL, racer_main, &racers[at]);
	for (int at = 0; at < 2; at++)
		pthread_join(threads[at], NULL);
	printf("%s %s\n", racers[0].ok ? "ok" : "bad", racers[1].ok ? "ok" : "bad");
}

int
main(int argc, char **argv)
{
	static char line[ERX_PROG_PATH_MAX + 256];
	char word[32], arg[ERX_PROG_PATH_MAX + 64], arg2[256];
	unsigned long long a, b;
	FILE *script;
	int fd;

	if (argc != 2 || (script = fopen(argv[1], "r")) == NULL)
		fail("usage: prog_file_driver SCRIPT");
	while (fgets(line, sizeof(line), script) != NULL) {
		line[strcspn(line, "\n")] = '\0';
		if (sscanf(line, "%31s", word) != 1)
			continue;
		if (strcmp(word, "slots") == 0 && sscanf(line, "%*s %llu", &a) == 1) {
			area_make((uint32_t)a);
			printf("ok\n");
		} else if (strcmp(word, "umask") == 0 && sscanf(line, "%*s %llo", &a) == 1) {
			self.umask = (uint16_t)a;
			printf("ok\n");
		} else if (strcmp(word, "open") == 0 && sscanf(line, "%*s %31s %s %255s %llo", word, arg, arg2, &a) == 4) {
			/* open DIRFD PATH FLAGS MODE: "cwd" for AT_FDCWD; "@" for no path, "%" for an empty one, "#N" for N bytes of 'a'. */
			const int dirfd = strcmp(word, "cwd") == 0 ? AT_FDCWD : atoi(word);

			if (arg[0] == '#') {
				const size_t n = strtoul(arg + 1, NULL, 10);

				if (n >= sizeof(arg))
					fail("a path too long for the driver");
				memset(arg, 'a', n);
				arg[n] = '\0';
			}
			if (strcmp(arg, "%") == 0)
				arg[0] = '\0';
			printf("%d\n", erx_prog_file_openat(dirfd, strcmp(arg, "@") == 0 ? NULL : arg, flags_of(arg2), (mode_t)a));
		} else if (strcmp(word, "write") == 0 && sscanf(line, "%*s %d %s", &fd, arg) == 2) {
			printf("%zd\n", erx_prog_fd_write(fd, arg, strlen(arg)));
		} else if (strcmp(word, "read") == 0 && sscanf(line, "%*s %d %llu", &fd, &a) == 2) {
			char buf[256] = { 0 };
			const ssize_t got = erx_prog_fd_read(fd, buf, a < sizeof(buf) - 1 ? (size_t)a : sizeof(buf) - 1);

			printf("%zd %s\n", got, got > 0 ? buf : "-");
		} else if (strcmp(word, "writen") == 0 && sscanf(line, "%*s %d %llu %llu", &fd, &a, &b) == 3) {
			printf("%zd\n", write_pattern(fd, (unsigned)a, (size_t)b));
		} else if (strcmp(word, "readn") == 0 && sscanf(line, "%*s %d %llu %llu", &fd, &a, &b) == 3) {
			do_readn(fd, (unsigned)a, (size_t)b);
		} else if (strcmp(word, "close") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			printf("%d\n", erx_prog_fd_close(fd));
		} else if (strcmp(word, "dup") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			printf("%d\n", erx_prog_fd_dup(fd));
		} else if (strcmp(word, "dupall") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			int n = 0;

			while (erx_prog_fd_dup(fd) >= 0)
				n++;
			printf("%d\n", n);
		} else if (strcmp(word, "lseek") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			printf("%lld\n", (long long)erx_prog_fd_lseek(fd, 0, SEEK_CUR));
		} else if (strcmp(word, "fstat") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			struct stat st;

			printf("%d\n", erx_prog_fd_fstat(fd, &st));
		} else if (strcmp(word, "fcntl") == 0 && sscanf(line, "%*s %d %31s %255s", &fd, arg, arg2) == 3) {
			/* fcntl FD getfd|getfl|setfl FLAGS: FLAGS as an open's, rdonly for none. */
			const int cmd = strcmp(arg, "getfd") == 0 ? F_GETFD : strcmp(arg, "getfl") == 0 ? F_GETFL : F_SETFL;

			printf("%ld\n", erx_prog_fd_fcntl(fd, cmd, flags_of(arg2)));
		} else if (strcmp(word, "fail") == 0 && sscanf(line, "%*s %llu", &a) == 1) {
			fail_next = (int)a;
			printf("ok\n");
		} else if (strcmp(word, "lie") == 0 && sscanf(line, "%*s %llu", &a) == 1) {
			lie_next = (uint32_t)a;
			printf("ok\n");
		} else if (strcmp(word, "probe") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			probe = fd;
			printf("ok\n");
		} else if (strcmp(word, "slow") == 0 && sscanf(line, "%*s %llu", &a) == 1) {
			slow = (uint32_t)a;
			printf("ok\n");
		} else if (strcmp(word, "race") == 0 && sscanf(line, "%*s %llu %llu", &a, &b) == 2) {
			do_race((unsigned)a, (size_t)b);
		} else if (strcmp(word, "log") == 0) {
			pthread_mutex_lock(&handler_lock);
			printf("%s\n", log_text[0] != '\0' ? log_text + 1 : "none");
			log_text[0] = '\0';
			pthread_mutex_unlock(&handler_lock);
		} else {
			fail(line);
		}
		fflush(stdout);
	}
	return (0);
}
