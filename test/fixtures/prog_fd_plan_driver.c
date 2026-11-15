/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of test/host/prog_fd_plan_test.rb over the descriptor
 * table's decisions (liberx/program/fd_plan.h).  It reads one request a line
 * from the file named on its command line and prints one answer a line, an
 * errno by its name and flags by their names joined with '+' ("-" for none),
 * so the test's model needs no value of the host's headers:
 *
 *   plans N                every dup over a table of N slots: one line
 *                          "MODE HELD FROM AT ANSWER" for each mode (lowest,
 *                          at), each set of held slots (HELD, a bit a slot),
 *                          each FROM from -1 to N and each AT from -2 to N+1
 *   dup3 OLD TO FLAGS      erx_prog_dup3_req: "ok FROM AT CLOEXEC" or the errno
 *   fcntl FD CMD ARG       erx_prog_fcntl_req: "OP ..." or the errno
 *   status ARG             erx_prog_status_set: the flags kept, or the errno
 *   seek AT OFF WHENCE END erx_prog_seek_plan: the offset, or the errno
 *
 * FLAGS and ARG name flags (nonblock, append, async, cloexec, oc for
 * O_CLOEXEC, rdwr, wronly, sync) joined with '+', or are a number.  CMD is
 * dupfd, dupfd_cloexec, getfd, setfd, getfl, setfl or getlk.  WHENCE is set,
 * cur, end, data or a number.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "liberx/program/fd_plan.h"

#define SLOTS_MAX	8

typedef struct named {
	const char	*name;
	long		 value;
} named_t;

static const named_t flags[] = {
	{ "nonblock", O_NONBLOCK }, { "append", O_APPEND }, { "async", O_ASYNC }, { "cloexec", FD_CLOEXEC },
	{ "oc", O_CLOEXEC }, { "rdwr", O_RDWR }, { "wronly", O_WRONLY }, { "sync", O_SYNC },
};
static const named_t cmds[] = {
	{ "dupfd", F_DUPFD }, { "dupfd_cloexec", F_DUPFD_CLOEXEC }, { "getfd", F_GETFD }, { "setfd", F_SETFD },
	{ "getfl", F_GETFL }, { "setfl", F_SETFL }, { "getlk", F_GETLK },
};
static const named_t whences[] = {
	{ "set", SEEK_SET }, { "cur", SEEK_CUR }, { "end", SEEK_END },
#ifdef SEEK_DATA
	{ "data", SEEK_DATA },
#endif
};
static const named_t errnos[] = {
	{ "EBADF", EBADF }, { "EINVAL", EINVAL }, { "EMFILE", EMFILE }, { "EOVERFLOW", EOVERFLOW },
};

static _Noreturn void
fail(const char *what)
{
	fprintf(stderr, "prog_fd_plan_driver: %s\n", what);
	exit(2);
}

static long
lookup(const named_t *table, size_t count, const char *name)
{
	for (size_t at = 0; at < count; at++) {
		if (strcmp(table[at].name, name) == 0)
			return (table[at].value);
	}
	fail(name);
}

/* A word of flag names joined with '+', or a number. */
static long
flags_of(const char *word)
{
	char copy[128], *rest = copy, *name;
	long value = 0;

	if ((word[0] >= '0' && word[0] <= '9') || word[0] == '-')
		return (strtol(word, NULL, 0));
	(void)snprintf(copy, sizeof(copy), "%s", word);
	while ((name = strsep(&rest, "+")) != NULL)
		value |= lookup(flags, sizeof(flags) / sizeof(flags[0]), name);
	return (value);
}

/* Prints the names of the status flags in value, the only ones a status may hold. */
static void
print_status(uint32_t value)
{
	const char *sep = "";

	if (value == 0)
		printf("-");
	if (value & O_NONBLOCK) {
		printf("%snonblock", sep);
		sep = "+";
	}
	if (value & O_APPEND)
		printf("%sappend", sep);
	if ((value & ~(uint32_t)(O_NONBLOCK | O_APPEND)) != 0)
		printf("+other");
	printf("\n");
}

static void
print_errno(int negative)
{
	for (size_t at = 0; at < sizeof(errnos) / sizeof(errnos[0]); at++) {
		if (-negative == errnos[at].value) {
			printf("%s\n", errnos[at].name);
			return;
		}
	}
	printf("errno%d\n", -negative);
}

static void
do_plans(uint32_t nslots)
{
	static char object;
	erx_prog_slot_t slots[SLOTS_MAX];

	if (nslots > SLOTS_MAX)
		fail("too many slots");
	for (int mode = 0; mode < 2; mode++) {
		for (uint32_t held = 0; held < (1U << nslots); held++) {
			for (uint32_t at = 0; at < nslots; at++)
				slots[at] = (erx_prog_slot_t){ .obj = (held >> at & 1) != 0 ? (void *)&object : NULL };
			for (int from = -1; from <= (int)nslots; from++) {
				for (long at = -2; at <= (long)nslots + 1; at++) {
					const erx_prog_dup_t req = { .mode = mode == 0 ? ERX_PROG_DUP_LOWEST : ERX_PROG_DUP_AT,
					    .from = from, .at = at };
					const int answer = erx_prog_dup_plan(slots, nslots, req);

					printf("%s %" PRIu32 " %d %ld ", mode == 0 ? "lowest" : "at", held, from, at);
					if (answer >= 0)
						printf("%d\n", answer);
					else
						print_errno(answer);
				}
			}
		}
	}
}

static void
print_dup(const erx_prog_dup_t *dup)
{
	printf("%s %d %ld %s\n", dup->mode == ERX_PROG_DUP_AT ? "at" : "lowest", dup->from, dup->at,
	    dup->cloexec ? "cloexec" : "-");
}

static void
do_fcntl(int fd, const char *cmd, const char *arg)
{
	erx_prog_fcntl_t out;
	const int status = erx_prog_fcntl_req(fd, (int)lookup(cmds, sizeof(cmds) / sizeof(cmds[0]), cmd),
	    flags_of(arg), &out);

	if (status != 0) {
		print_errno(status);
		return;
	}
	switch (out.op) {
	case ERX_PROG_FCNTL_DUP:
		printf("dup ");
		print_dup(&out.u.dup);
		break;
	case ERX_PROG_FCNTL_GETFD:
		printf("getfd\n");
		break;
	case ERX_PROG_FCNTL_SETFD:
		printf("setfd %s\n", out.u.cloexec ? "cloexec" : "-");
		break;
	case ERX_PROG_FCNTL_GETFL:
		printf("getfl\n");
		break;
	case ERX_PROG_FCNTL_SETFL:
		printf("setfl %s\n", out.u.status == flags_of(arg) ? "arg" : "changed");
		break;
	}
}

int
main(int argc, char **argv)
{
	char line[256], word[16], a[64], b[64], c[64];
	long long x, y, z;
	FILE *requests;

	if (argc != 2 || (requests = fopen(argv[1], "r")) == NULL)
		fail("usage: prog_fd_plan_driver REQUESTS");
	while (fgets(line, sizeof(line), requests) != NULL) {
		if (sscanf(line, "%15s", word) != 1)
			continue;
		if (strcmp(word, "plans") == 0 && sscanf(line, "%*s %lld", &x) == 1) {
			do_plans((uint32_t)x);
		} else if (strcmp(word, "dup3") == 0 && sscanf(line, "%*s %lld %lld %63s", &x, &y, a) == 3) {
			erx_prog_dup_t req;
			const int status = erx_prog_dup3_req((int)x, (int)y, (int)flags_of(a), &req);

			if (status != 0) {
				print_errno(status);
			} else {
				printf("ok ");
				print_dup(&req);
			}
		} else if (strcmp(word, "fcntl") == 0 && sscanf(line, "%*s %lld %63s %63s", &x, a, b) == 3) {
			do_fcntl((int)x, a, b);
		} else if (strcmp(word, "status") == 0 && sscanf(line, "%*s %63s", a) == 1) {
			uint32_t kept = 0;
			const int status = erx_prog_status_set(flags_of(a), &kept);

			if (status != 0)
				print_errno(status);
			else
				print_status(kept);
		} else if (strcmp(word, "seek") == 0 && sscanf(line, "%*s %lld %lld %63s %lld", &x, &y, c, &z) == 4) {
			const bool named = c[0] < '0' || c[0] > '9';
			const int whence = named ? (int)lookup(whences, sizeof(whences) / sizeof(whences[0]), c) :
			    (int)strtol(c, NULL, 10);
			int64_t to = 0;
			const int status = erx_prog_seek_plan(x, y, whence, z, &to);

			if (status != 0)
				print_errno(status);
			else
				printf("%" PRId64 "\n", to);
		} else {
			fail(line);
		}
	}
	return (0);
}
