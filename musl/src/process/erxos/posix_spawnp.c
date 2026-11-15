/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * posix_spawnp on erXos (docs/design-programs.md, "What a program can
 * start"): a file without a slash is searched for in PATH, /bin when PATH
 * is unset, with access and X_OK through the program's namespace, and the
 * first hit is spawned.  As FreeBSD's execvp, an empty element is the
 * working directory, an element the file is not in or that is too long is
 * passed over, and the search ends in EACCES when some element held the
 * file without letting it run, ENOENT otherwise.  Any other error of access
 * ends the search with it.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int
posix_spawnp(pid_t *restrict pid, const char *restrict file, const posix_spawn_file_actions_t *fa,
    const posix_spawnattr_t *restrict attr, char *const argv[restrict], char *const envp[restrict])
{
	const char *search = getenv("PATH");
	const size_t len = strnlen(file, NAME_MAX + 1);
	char path[PATH_MAX];
	bool denied = false;

	if (file[0] == '\0' || strchr(file, '/') != NULL)
		return (posix_spawn(pid, file, fa, attr, argv, envp));
	if (len > NAME_MAX)
		return (ENAMETOOLONG);
	if (search == NULL)
		search = "/bin";
	for (const char *dir = search;; dir++) {
		const char *end = strchrnul(dir, ':');
		const size_t dir_len = (size_t)(end - dir);

		if (dir_len + 1 + len < sizeof(path)) {
			/* An empty element is the working directory: the file alone, no "/". */
			memcpy(path, dir, dir_len);
			path[dir_len] = '/';
			memcpy(path + dir_len + (dir_len != 0), file, len + 1);
			if (access(path, X_OK) == 0)
				return (posix_spawn(pid, path, fa, attr, argv, envp));
			if (errno == EACCES)
				denied = true;
			else if (errno != ENOENT && errno != ENOTDIR && errno != ENAMETOOLONG)
				return (errno);
		}
		if (*end == '\0')
			break;
		dir = end;
	}
	return (denied ? EACCES : ENOENT);
}
