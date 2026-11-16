/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A session's program as a task (docs/design-programs.md, "Starting a program", step 9):
 * the first thread hands its argument registers, the values of the program's install, to
 * liberx's program layer, and musl's start enters the layer's start-up, which calls the
 * program's main once its startup message is accepted. main's status stops the task, and
 * the session's fault gate reads it.
 *
 * musl offers the program's descriptor seam every call (libc_start.h). It hands back a
 * closed list of calls that name no descriptor, and answers every other from the program
 * layer's descriptor table (liberx/program/fd.h): a program writes only to the descriptors
 * its session installed, and a descriptor the table does not hold is EBADF, never the
 * console. rt_sigaction is answered from the program's dispositions
 * (liberx/program/signal.h).
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>

#include "erx/abi.h"
#include "liberx/libc_spawn.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/api.h"
#include "liberx/program/fd.h"
#include "liberx/program/file.h"
#include "liberx/program/pipe.h"
#include "liberx/program/poll.h"
#include "liberx/program/signal.h"
#include "liberx/program/spawn.h"
#include "liberx/program/program.h"

/* The seam takes every write, so musl's console row is never reached from a program. */
void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	(void)bytes;
	(void)length;
	__builtin_trap();
}

/*
 * mmap through the seam, its arguments in the call's order. PROT_EXEC is ENOTSUP before
 * anything else, and a fixed range must miss the mem range; an anonymous mapping is then
 * musl's to make (false), and a mapping of a descriptor the table's.
 */
static bool
mmap_call(const long args[6], long *result)
{
	const uint64_t addr = (uint64_t)args[0], len = (uint64_t)args[1];
	const int prot = (int)args[2], flags = (int)args[3], fd = (int)args[4];
	const off_t offset = (off_t)args[5];
	void *where = NULL;
	int status;

	if ((prot & PROT_EXEC) != 0) {
		*result = -ENOTSUP;
		return (true);
	}
	if (flags & MAP_FIXED) {
		status = erx_prog_fd_fixed_check(addr, len);
		if (status != 0) {
			*result = status;
			return (true);
		}
	}
	if (flags & MAP_ANONYMOUS)
		return (false);
	status = erx_prog_fd_mmap(fd, (size_t)len, prot, flags, offset, &where);
	*result = status != 0 ? status : (long)(uintptr_t)where;
	return (true);
}

/*
 * ppoll, its arguments in the call's order. No signal is ever caught in a program on the
 * stopgap (liberx/program/signal.h), so the mask a ppoll would hold during the wait
 * changes nothing; its size is still checked, as Linux checks it, so a caller that
 * passes one learns of a wrong size.
 */
static long
ppoll_call(struct pollfd *fds, unsigned long nfds, const struct timespec *timeout, bool masked, size_t mask_size)
{
	uint64_t deadline;
	int status;

	if (masked && mask_size != _NSIG / 8)
		return (-EINVAL);
	status = erx_prog_poll_deadline(erx_clock_ns(), timeout, &deadline);
	if (status != 0)
		return (status);
	return (erx_prog_poll(fds, (size_t)nfds, deadline));
}

bool
erx_libc_spawn(const struct erx_spawn_request *req, long *result)
{
	pid_t pid;
	int error;

	error = erx_prog_spawn(&pid, req);
	*result = error != 0 ? -error : pid;
	return (true);
}

/*
 * Whether an *at call names directory descriptor dir with path: not for AT_FDCWD, nor for
 * an absolute path, which FreeBSD resolves without the descriptor.
 */
static bool
at_names(int dir, const char *path)
{
	return (dir != AT_FDCWD && (path == NULL || path[0] != '/'));
}

/*
 * An *at call the table does not offer: -EBADF for a directory descriptor it names and the
 * table does not hold, else ENOSYS. other and other_path are the call's second directory
 * descriptor and path, AT_FDCWD and NULL for a call with one.
 */
static long
at_unoffered(int dir, const char *path, int other, const char *other_path)
{
	if (at_names(dir, path) && erx_prog_fd_held_or(dir, 0) != 0)
		return (-EBADF);
	if (at_names(other, other_path))
		return (erx_prog_fd_held_or(other, -ENOSYS));
	return (-ENOSYS);
}

/*
 * musl offers the seam every call (libc_start.h). The first group is the closed list of
 * calls that name no descriptor, which go back to musl's own rows; only the loader maps
 * code (docs/design-programs.md, P10), so PROT_EXEC in mmap and mprotect never reaches a
 * row. Every other call is the table's: the calls it offers; the calls naming a descriptor
 * that it does not offer, EBADF for one it does not hold and ENOSYS for one it does; and
 * any other call ENOSYS, as musl's default answers it. So no call of a program reaches a
 * row of musl's that names a descriptor, the console's included.
 */
bool
erx_fiasco_libc_fd(long n, const long args[6], long *result)
{
	const int fd = (int)args[0];

	switch (n) {
	case SYS_futex:
	case SYS_brk:
	case SYS_clock_gettime:
	case SYS_clock_nanosleep:
	case SYS_nanosleep:
	case SYS_set_tid_address:
	case SYS_gettid:
	case SYS_getpid:
	case SYS_getppid:
	case SYS_getuid:
	case SYS_geteuid:
	case SYS_getgid:
	case SYS_getegid:
	case SYS_exit:
	case SYS_exit_group:
	case SYS_sched_setaffinity:
	case SYS_sched_yield:
	case SYS_tkill:
	case SYS_rt_sigprocmask:
	case SYS_set_robust_list:
	case SYS_get_robust_list:
	case SYS_getrandom:
		return (false);
	case SYS_mprotect:
		if (((int)args[2] & PROT_EXEC) == 0)
			return (false);
		*result = -ENOTSUP;
		return (true);
	case SYS_mmap:
		return (mmap_call(args, result));
	case SYS_munmap:
		*result = erx_prog_fd_munmap((uint64_t)args[0], (uint64_t)args[1]);
		return (true);
	case SYS_read:
		*result = erx_prog_fd_read(fd, (void *)args[1], (size_t)args[2]);
		return (true);
	case SYS_write:
		*result = erx_prog_fd_write(fd, (const void *)args[1], (size_t)args[2]);
		return (true);
	case SYS_readv:
		*result = erx_prog_fd_readv(fd, (const struct iovec *)args[1], (int)args[2]);
		return (true);
	case SYS_writev:
		*result = erx_prog_fd_writev(fd, (const struct iovec *)args[1], (int)args[2]);
		return (true);
	case SYS_openat:
		*result = erx_prog_file_openat(fd, (const char *)args[1], (int)args[2], (mode_t)args[3]);
		return (true);
	case SYS_close:
		*result = erx_prog_fd_close(fd);
		return (true);
	case SYS_dup:
		*result = erx_prog_fd_dup(fd);
		return (true);
	case SYS_dup3:
		*result = erx_prog_fd_dup3(fd, (int)args[1], (int)args[2]);
		return (true);
	case SYS_pipe2:
		/* musl's pipe() is pipe2(fd, 0) where the architecture has no pipe call (src/unistd/pipe.c). */
		*result = erx_prog_pipe2((int *)args[0], (int)args[1]);
		return (true);
	case SYS_fcntl:
		*result = erx_prog_fd_fcntl(fd, (int)args[1], args[2]);
		return (true);
	case SYS_lseek:
		*result = erx_prog_fd_lseek(fd, (off_t)args[1], (int)args[2]);
		return (true);
	case SYS_fstat:
		*result = erx_prog_fd_fstat(fd, (struct stat *)args[1]);
		return (true);
	case SYS_ioctl:
		*result = erx_prog_fd_ioctl(fd, (unsigned long)args[1], (void *)args[2]);
		return (true);
	case SYS_ppoll:
		*result = ppoll_call((struct pollfd *)args[0], (unsigned long)args[1], (const struct timespec *)args[2],
		    args[3] != 0, (size_t)args[4]);
		return (true);
	case SYS_rt_sigaction:
		/* musl's switch hands the seam struct sigaction, not the kernel's layout (libc_start.h). */
		*result = erx_prog_sigaction((int)args[0], (const struct sigaction *)args[1], (struct sigaction *)args[2]);
		return (true);
	case SYS_pread64:
		*result = erx_prog_fd_pread(fd, (void *)args[1], (size_t)args[2], (off_t)args[3]);
		return (true);
	case SYS_pwrite64:
		*result = erx_prog_fd_pwrite(fd, (const void *)args[1], (size_t)args[2], (off_t)args[3]);
		return (true);
	case SYS_preadv:
	case SYS_pwritev:
	case SYS_preadv2:
	case SYS_pwritev2:
	case SYS_fsync:
	case SYS_fdatasync:
	case SYS_syncfs:
	case SYS_sync_file_range:
	case SYS_ftruncate:
	case SYS_fallocate:
	case SYS_fadvise64:
	case SYS_readahead:
	case SYS_getdents64:
	case SYS_fchdir:
	case SYS_fchmod:
	case SYS_fchown:
	case SYS_fstatfs:
	case SYS_flock:
	case SYS_fgetxattr:
	case SYS_fsetxattr:
	case SYS_flistxattr:
	case SYS_fremovexattr:
	case SYS_sendfile:
	case SYS_bind:
	case SYS_listen:
	case SYS_accept:
	case SYS_accept4:
	case SYS_connect:
	case SYS_getsockname:
	case SYS_getpeername:
	case SYS_sendto:
	case SYS_recvfrom:
	case SYS_setsockopt:
	case SYS_getsockopt:
	case SYS_shutdown:
	case SYS_sendmsg:
	case SYS_recvmsg:
	case SYS_sendmmsg:
	case SYS_recvmmsg:
	case SYS_copy_file_range:
	case SYS_splice:
	case SYS_tee:
	case SYS_vmsplice:
	case SYS_epoll_ctl:
	case SYS_epoll_pwait:
	case SYS_epoll_pwait2:
	case SYS_inotify_add_watch:
	case SYS_inotify_rm_watch:
	case SYS_fanotify_mark:
	case SYS_timerfd_settime:
	case SYS_timerfd_gettime:
	case SYS_setns:
	case SYS_mq_timedsend:
	case SYS_mq_timedreceive:
	case SYS_mq_notify:
	case SYS_mq_getsetattr:
		*result = erx_prog_fd_held_or(fd, -ENOSYS);
		return (true);
	case SYS_openat2:
	case SYS_mkdirat:
	case SYS_mknodat:
	case SYS_unlinkat:
	case SYS_faccessat:
	case SYS_faccessat2:
	case SYS_fchmodat:
	case SYS_fchmodat2:
	case SYS_fchownat:
	case SYS_readlinkat:
	case SYS_newfstatat:
	case SYS_statx:
	case SYS_utimensat:
	case SYS_execveat:
	case SYS_name_to_handle_at:
		*result = at_unoffered(fd, (const char *)args[1], AT_FDCWD, NULL);
		return (true);
	case SYS_symlinkat:
		*result = at_unoffered((int)args[1], (const char *)args[2], AT_FDCWD, NULL);
		return (true);
	case SYS_linkat:
	case SYS_renameat:
	case SYS_renameat2:
		*result = at_unoffered(fd, (const char *)args[1], (int)args[2], (const char *)args[3]);
		return (true);
	default:
		/* pselect6 among them: the table does not offer it. */
		*result = -ENOSYS;
		return (true);
	}
}

/*
 * musl's start runs before the startup message arrives, so a program's AT_HWCAP and
 * AT_HWCAP2 come from its argument registers: its session's own feature words, in the
 * registers program_arg's hwcap and hwcap2 name.
 */
int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	erx_prog_enter(args);
	return (erx_fiasco_libc_start(liberx_program_main, (erx_fiasco_cpu_features_t){
	    .hwcap = args[ERX_PROGRAM_ARG_HWCAP], .hwcap2 = args[ERX_PROGRAM_ARG_HWCAP2] }));
}
