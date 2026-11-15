/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_SPAWN_PLAN_H
#define LIBERX_PROGRAM_SPAWN_PLAN_H

/*
 * The spawn planner (docs/design-programs.md, "Starting a program", step 1):
 * a pure function from what posix_spawn was asked for and what the starter
 * holds to the child's start, before anything is sent.  It replays the file
 * actions, in the order they were added, on a model of the child's
 * descriptor table that starts as a copy of the starter's, then drops what
 * exec would close, as FreeBSD's posix_spawn does in its child:
 *
 *  - addclose empties its slot, and a close of an empty slot is no error;
 *  - adddup2 makes its target name the source's object without FD_CLOEXEC,
 *    a dup2 of a descriptor onto itself included, and fails with EBADF for
 *    an empty source or a number past the table;
 *  - addopen makes its descriptor a new open without FD_CLOEXEC, whatever
 *    oflag asks, and fails with EMFILE when the table has no empty slot for
 *    the open to land in first;
 *  - addchdir moves the working directory the child starts in;
 *  - addfchdir names a directory descriptor: EBADF for an empty slot, and
 *    ENOTDIR for a null, a pipe end or a mem range, none of which is one.
 *
 * Then every descriptor with FD_CLOEXEC goes, and so does a mem range,
 * which names a mapping of the starter's own sub-space (docs/design-programs.md,
 * "The startup message").  The child names each object the starter holds
 * once: a second number for the same object is a dup of the first.
 *
 * The planner reads only its arguments and writes only its plan, so it
 * builds and is tested on the host.  It never fails half way: a refused
 * plan returns its error with nothing sent and every input unchanged.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <erx/abi.h>

#include "liberx/program/fd.h"
#include "liberx/program/startup.h"

typedef enum erx_spawn_op {
	ERX_SPAWN_CLOSE,	/* posix_spawn_file_actions_addclose */
	ERX_SPAWN_DUP2,		/* posix_spawn_file_actions_adddup2 */
	ERX_SPAWN_OPEN,		/* posix_spawn_file_actions_addopen */
	ERX_SPAWN_CHDIR,	/* posix_spawn_file_actions_addchdir_np */
	ERX_SPAWN_FCHDIR	/* posix_spawn_file_actions_addfchdir_np */
} erx_spawn_op_t;

/*
 * One file action.  A posix_spawn_file_actions_t holds a list of them in
 * the order they were added, which is the order they apply in.  fd is the
 * child's descriptor the action sets (every op but CHDIR), src the
 * descriptor DUP2 copies, oflag and mode OPEN's, and path OPEN's and
 * CHDIR's, NUL-terminated.
 */
typedef struct erx_spawn_action {
	struct erx_spawn_action	*next;
	erx_spawn_op_t		 op;
	int			 fd;
	int			 src;
	int			 oflag;
	mode_t			 mode;
	char			 path[];
} erx_spawn_action_t;

/* The attributes posix_spawn honors; posix_spawnattr_t's flags decoded. */
typedef struct erx_spawn_attr {
	bool			 sets_mask;	/* POSIX_SPAWN_SETSIGMASK: the child's mask is mask */
	erx_prog_sigset_t	 mask;
	bool			 sets_defaults;	/* POSIX_SPAWN_SETSIGDEF: defaults start at SIG_DFL */
	erx_prog_sigset_t	 defaults;
	/*
	 * POSIX_SPAWN_SETPGROUP, POSIX_SPAWN_SETSID, POSIX_SPAWN_SETSCHEDULER
	 * or POSIX_SPAWN_SETSCHEDPARAM, which the first tier refuses with
	 * ENOSYS (docs/design-programs.md, "The POSIX-lite personality").
	 * POSIX_SPAWN_RESETIDS changes nothing, since a program's real and
	 * effective ids are both its principal's.
	 */
	bool			 sets_group_session_or_policy;
} erx_spawn_attr_t;

/* What the caller of posix_spawn asked for. */
typedef struct erx_spawn_request {
	const char		 *path;
	char *const		 *argv;
	char *const		 *envp;
	const erx_spawn_action_t *actions;	/* the first, or NULL for none */
	erx_spawn_attr_t	  attr;
	erx_prog_sigset_t	  mask;		/* the calling thread's */
} erx_spawn_request_t;

/* One slot of the starter's descriptor table: its object, NULL when empty, and FD_CLOEXEC. */
typedef struct erx_spawn_slot {
	erx_prog_obj_t	*obj;
	bool			 cloexec;
} erx_spawn_slot_t;

/* What the starter holds when it plans. */
typedef struct erx_spawn_starter {
	const erx_spawn_slot_t	*table;		/* ERX_PROG_FDS_MAX slots */
	erx_prog_sigset_t	 ignored;	/* the signals at SIG_IGN, never SIGKILL or SIGSTOP */
	uint16_t		 umask;
	const char		*cwd;		/* absolute and normalised, as the startup message's */
} erx_spawn_starter_t;

typedef enum erx_spawn_fd_kind {
	ERX_SPAWN_FD_NONE,	/* the child has no such descriptor */
	ERX_SPAWN_FD_HELD,	/* held: an object of the starter's table, a null or a pipe end */
	ERX_SPAWN_FD_OPEN,	/* open: the ERX_SPAWN_OPEN action whose open it is */
	ERX_SPAWN_FD_DUP	/* dup: the same object as the lower descriptor dup, which is no dup */
} erx_spawn_fd_kind_t;

typedef struct erx_spawn_fd {
	erx_spawn_fd_kind_t	kind;
	union {
		erx_prog_obj_t		 *held;
		const erx_spawn_action_t *open;
		uint16_t		  dup;
	};
} erx_spawn_fd_t;

/*
 * A spawn's plan, the startup message's fields the starter gives: the
 * executable's path, absolute and normalised against the working
 * directory the child starts in, as exec in FreeBSD's child resolves it;
 * argv and env, borrowed from the request, with
 * args_bytes their lengths with one NUL each; the working directory; the
 * child's mask and ignored signals, each a set of signals a program may
 * name, the mask never holding SIGKILL or SIGSTOP; the file mode creation
 * mask; and the child's descriptors, by number.  Every ERX_SPAWN_OPEN
 * action is an open the starter makes, in order, whether or not a
 * descriptor of the child still names it, since open's effects on the file
 * (O_CREAT, O_TRUNC) happen either way.
 */
typedef struct erx_spawn_plan {
	char			 path[ERX_PROG_PATH_MAX + 1];
	char *const		*argv;
	char *const		*envp;
	size_t			 args_bytes;
	char			 cwd[ERX_PROG_PATH_MAX + 1];
	erx_prog_sigset_t	 sigmask;
	erx_prog_sigset_t	 sigignore;
	uint16_t		 umask;
	erx_spawn_fd_t		 fds[ERX_PROG_FDS_MAX];
} erx_spawn_plan_t;

/*
 * Plans the spawn req asks of starter into *plan: 0, or the error
 * posix_spawn returns, with *plan meaningless.  EFAULT for a NULL argv or
 * envp, ENOENT for an empty path, an empty addopen path or an empty
 * addchdir path, ENAMETOOLONG for a path, or a working directory or open
 * path it makes, longer than ERX_PROG_PATH_MAX, E2BIG for argv and env past
 * ERX_PROG_ARGS_MAX, ENOSYS for a process group, a session or a scheduling
 * policy, and the file actions' errors above, the first action that fails
 * deciding among the errors a plan can see.  What only the opens and the
 * handler can find (a missing file, a working directory that is no
 * directory) comes later, from the send (TODO.md).
 */
int	erx_spawn_plan(const erx_spawn_request_t *req, const erx_spawn_starter_t *starter,
	    erx_spawn_plan_t *plan);

#endif /* !LIBERX_PROGRAM_SPAWN_PLAN_H */
