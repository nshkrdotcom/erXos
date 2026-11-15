/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that writes a file and reads it back through
 * its handler (tools/lib/erx/programs.rb; liberx/program/file.h): musl's
 * open, write, read and close reach liberx's file client through the
 * descriptor seam, each a request on the program's channel, and the bytes
 * move through the data area.  argv[1] names the file, which the program's
 * namespace must let it create.  It writes a short text, then a block of
 * three data slots and a part, so the write and the read back each go in
 * parts; reads both back in order through a second open, finds the end of
 * the file, checks that a dup shares the open's offset, and ends with 0, or
 * with a code of its own for the first step that does not agree.
 */

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

int	main(int, char **);

static const char text[] = "hello, file\n";

/* Three slots of 64 KiB and a part of one. */
#define BLOCK	(3 * 65536 + 1000)

static uint8_t block[BLOCK];
static uint8_t back[BLOCK];

/* The byte at offset of the block: never the same for neighbours within a slot. */
static uint8_t
pattern(size_t offset)
{
	return ((uint8_t)(offset * 7 + offset / 251));
}

/* Reads exactly len bytes into buf, as many reads as it takes: whether all came. */
static int
read_all(int fd, uint8_t *buf, size_t len)
{
	size_t total = 0;

	while (total < len) {
		const ssize_t got = read(fd, buf + total, len - total);

		if (got <= 0)
			return (0);
		total += (size_t)got;
	}
	return (1);
}

int
main(int argc, char **argv)
{
	char small[sizeof(text)];
	int fd, copy;

	if (argc != 2)
		return (1);
	for (size_t at = 0; at < BLOCK; at++)
		block[at] = pattern(at);

	fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return (2);
	if (write(fd, text, sizeof(text) - 1) != (ssize_t)(sizeof(text) - 1))
		return (3);
	if (write(fd, block, BLOCK) != BLOCK)
		return (4);
	if (close(fd) != 0)
		return (5);

	fd = open(argv[1], O_RDONLY);
	if (fd < 0)
		return (6);
	memset(small, 0, sizeof(small));
	if (read(fd, small, sizeof(text) - 1) != (ssize_t)(sizeof(text) - 1) || memcmp(small, text, sizeof(text) - 1) != 0)
		return (7);
	/* A dup names the same open, so it reads on from the same offset. */
	copy = dup(fd);
	if (copy < 0)
		return (8);
	if (!read_all(copy, back, BLOCK) || memcmp(back, block, BLOCK) != 0)
		return (9);
	if (read(fd, small, 1) != 0)
		return (10);
	if (close(copy) != 0 || close(fd) != 0)
		return (11);
	/* Both closed: the descriptor is gone. */
	if (read(fd, small, 1) != -1 || errno != EBADF)
		return (12);

	if (open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0644) != -1 || errno != EEXIST)
		return (13);
	return (0);
}
