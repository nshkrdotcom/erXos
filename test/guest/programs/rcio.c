/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that the command shell runs
 * (tools/lib/erx/programs.rb): "rcio hello WORD..." writes "rcio: " and its
 * words to standard output and exits 3; "rcio upcase" copies standard input
 * to standard output in upper case and exits 0 at its end; "rcio loop"
 * writes "rcio: looping" and runs until a signal ends it.
 */

#include <string.h>
#include <unistd.h>

int	main(int, char **);

static int
put(const char *text, size_t length)
{
	while (length > 0) {
		const ssize_t wrote = write(1, text, length);

		if (wrote <= 0)
			return (-1);
		text += wrote;
		length -= (size_t)wrote;
	}
	return (0);
}

static int
hello(int argc, char **argv)
{
	if (put("rcio:", 5) != 0)
		return (1);
	for (int i = 2; i < argc; i++)
		if (put(" ", 1) != 0 || put(argv[i], strlen(argv[i])) != 0)
			return (1);
	return (put("\n", 1) == 0 ? 3 : 1);
}

static int
upcase(void)
{
	char buffer[512];
	ssize_t got;

	while ((got = read(0, buffer, sizeof(buffer))) > 0) {
		for (ssize_t i = 0; i < got; i++)
			if (buffer[i] >= 'a' && buffer[i] <= 'z')
				buffer[i] = (char)(buffer[i] - 'a' + 'A');
		if (put(buffer, (size_t)got) != 0)
			return (1);
	}
	return (got == 0 ? 0 : 1);
}

int
main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "hello") == 0)
		return (hello(argc, argv));
	if (argc == 2 && strcmp(argv[1], "upcase") == 0)
		return (upcase());
	if (argc == 2 && strcmp(argv[1], "loop") == 0) {
		if (put("rcio: looping\n", 14) != 0)
			return (1);
		for (;;)
			;
	}
	return (2);
}
