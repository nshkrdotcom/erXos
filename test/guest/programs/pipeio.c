/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program for poll and SIGPIPE (tools/lib/erx/programs.rb), given
 * descriptor 3, a pipe write end whose pipe has no read end. argv[1] names the check:
 *
 * - poll: poll answers POLLOUT|POLLHUP for the write end, as FreeBSD's pipe_poll does
 *   once no reader remains, POLLNVAL for a descriptor the table does not hold, EINVAL for
 *   more descriptors than the table has, and 0 once a timeout of 50 ms has passed;
 * - sigign: signal(SIGPIPE, SIG_IGN) succeeds, sigaction with a handler fails with
 *   EINVAL, and the write fails with EPIPE;
 * - dup: dup, dup2, dup3, fcntl and the generic ioctls answer as FreeBSD does, FD_CLOEXEC
 *   the slot's and the status flags the open's, lseek is ESPIPE whatever the whence, and
 *   with SIGPIPE ignored a writev and a write on the end fail with EPIPE;
 * - sigdfl: the write raises SIGPIPE under its default action, which ends the program
 *   by the signal before the write returns.
 * - pipe, given no descriptor 3 and a session with two pipes left of its quota: a pipe's
 *   bytes come back through it, its read end reads the end of the stream once its write
 *   end is closed, pipe2 with O_CLOEXEC sets FD_CLOEXEC on both ends, with O_NONBLOCK an
 *   empty read fails with EAGAIN and with any other flag pipe2 fails with EINVAL; then
 *   pipe makes the two pipes left and fails with ENFILE at the session's quota.
 *
 * main returns 42 when every check of its mode held, else the number of the first that
 * failed, so the case's answer names it.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define PIPE_FD		3
#define TIMEOUT_MS	50
#define TOO_MANY	1025	/* one past ERX_PROG_FDS_MAX */

int	main(int, char **);

static void
caught(int signo)
{
	(void)signo;
}

static int64_t
now_ms(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int
poll_checks(void)
{
	static struct pollfd many[TOO_MANY];
	struct pollfd end = { .fd = PIPE_FD, .events = POLLIN | POLLOUT };
	struct pollfd none = { .fd = 9, .events = POLLIN };
	int64_t start;

	if (poll(&end, 1, 0) != 1 || end.revents != (POLLOUT | POLLHUP))
		return (1);
	if (poll(&none, 1, 0) != 1 || none.revents != POLLNVAL)
		return (2);
	for (int i = 0; i < TOO_MANY; i++)
		many[i] = (struct pollfd){ .fd = -1 };
	if (poll(many, TOO_MANY, 0) != -1 || errno != EINVAL)
		return (3);
	start = now_ms();
	if (poll(NULL, 0, TIMEOUT_MS) != 0 || now_ms() - start < TIMEOUT_MS)
		return (4);
	return (42);
}

static int
sigign_checks(void)
{
	struct sigaction handler = { .sa_handler = caught };

	if (signal(SIGPIPE, SIG_IGN) != SIG_DFL)
		return (1);
	if (sigaction(SIGTERM, &handler, NULL) != -1 || errno != EINVAL)
		return (2);
	if (write(PIPE_FD, "x", 1) != -1 || errno != EPIPE)
		return (3);
	return (42);
}

/*
 * The dup mode: the descriptor calls on descriptor 3 through musl, each answer as FreeBSD
 * gives it; the write's EPIPE closes it, with SIGPIPE ignored.
 */
static int
dup_checks(void)
{
	static const struct iovec two[] = { { .iov_base = "a", .iov_len = 1 }, { .iov_base = "bc", .iov_len = 2 } };
	const int off = 0;

	if (dup(PIPE_FD) != 0 || fcntl(0, F_GETFD) != 0)
		return (1);
	if (fcntl(PIPE_FD, F_SETFD, FD_CLOEXEC) != 0 || fcntl(PIPE_FD, F_GETFD) != FD_CLOEXEC)
		return (2);
	if (dup(PIPE_FD) != 1 || fcntl(1, F_GETFD) != 0)
		return (3);
	if (fcntl(PIPE_FD, F_DUPFD_CLOEXEC, 10) != 10 || fcntl(10, F_GETFD) != FD_CLOEXEC)
		return (4);
	if (dup2(PIPE_FD, PIPE_FD) != PIPE_FD || dup3(PIPE_FD, PIPE_FD, 0) != -1 || errno != EINVAL)
		return (5);
	if (dup3(PIPE_FD, 7, O_CLOEXEC) != 7 || fcntl(7, F_GETFD) != FD_CLOEXEC || dup2(0, 7) != 7 ||
	    fcntl(7, F_GETFD) != 0)
		return (6);
	if (dup2(PIPE_FD, TOO_MANY - 1) != -1 || errno != EBADF || fcntl(PIPE_FD, F_DUPFD, TOO_MANY - 1) != -1 ||
	    errno != EINVAL)
		return (7);
	if (fcntl(PIPE_FD, F_GETFL) != O_WRONLY || fcntl(PIPE_FD, F_SETFL, O_NONBLOCK) != 0 ||
	    fcntl(0, F_GETFL) != (O_WRONLY | O_NONBLOCK))
		return (8);
	if (ioctl(0, FIONBIO, &off) != 0 || fcntl(PIPE_FD, F_GETFL) != O_WRONLY ||
	    fcntl(PIPE_FD, F_SETFL, O_ASYNC) != -1 || errno != EINVAL)
		return (9);
	if (lseek(PIPE_FD, 0, SEEK_CUR) != -1 || errno != ESPIPE || lseek(PIPE_FD, 0, 99) != -1 || errno != ESPIPE)
		return (10);
	if (ioctl(PIPE_FD, FIONCLEX) != 0 || fcntl(PIPE_FD, F_GETFD) != 0)
		return (11);
	if (signal(SIGPIPE, SIG_IGN) != SIG_DFL || writev(7, two, 2) != -1 || errno != EPIPE)
		return (12);
	if (close(0) != 0 || close(1) != 0 || close(7) != 0 || close(10) != 0 || close(7) != -1 || errno != EBADF)
		return (13);
	if (write(PIPE_FD, "x", 1) != -1 || errno != EPIPE)
		return (14);
	return (42);
}

/* The pipe mode: the pipes it makes are the program's own, each closed before the next. */
static int
pipe_checks(void)
{
	char buf[8];
	int p[2], q[2], r[2];

	if (pipe(p) != 0 || p[0] == p[1] || write(p[1], "ping", 4) != 4 || read(p[0], buf, sizeof(buf)) != 4 ||
	    memcmp(buf, "ping", 4) != 0)
		return (1);
	if (close(p[1]) != 0 || read(p[0], buf, sizeof(buf)) != 0 || close(p[0]) != 0)
		return (2);
	if (pipe2(p, O_CLOEXEC) != 0 || fcntl(p[0], F_GETFD) != FD_CLOEXEC || fcntl(p[1], F_GETFD) != FD_CLOEXEC ||
	    close(p[0]) != 0 || close(p[1]) != 0)
		return (3);
	if (pipe2(p, O_NONBLOCK) != 0 || fcntl(p[0], F_GETFD) != 0 || read(p[0], buf, sizeof(buf)) != -1 ||
	    errno != EAGAIN || close(p[0]) != 0 || close(p[1]) != 0)
		return (4);
	if (pipe2(p, O_APPEND) != -1 || errno != EINVAL)
		return (5);
	if (pipe(p) != 0 || pipe(q) != 0)
		return (6);
	if (pipe(r) != -1 || errno != ENFILE)
		return (7);
	return (42);
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "poll") == 0)
		return (poll_checks());
	if (argc == 2 && strcmp(argv[1], "sigign") == 0)
		return (sigign_checks());
	if (argc == 2 && strcmp(argv[1], "dup") == 0)
		return (dup_checks());
	if (argc == 2 && strcmp(argv[1], "pipe") == 0)
		return (pipe_checks());
	if (argc == 2 && strcmp(argv[1], "sigdfl") == 0) {
		(void)write(PIPE_FD, "x", 1);
		return (1);
	}
	return (99);
}
