/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The display suite's misbehaving renderer (tools/lib/erx/display_domain.rb,
 * the lvgl-damage and lvgl-confine cells): a program that erx_ui_lvgl starts
 * in erx-lvgl's place, with erx-lvgl's descriptors, and that breaks one rule
 * of the renderer's side of ui.txt or of its window's buffer, so the
 * session's verdict on it is the cell's (docs/design-display.md,
 * Verification, the kiosk's cells). It reads the screen record the renderer
 * writes at its start, so its own end races no write of the renderer's, then
 * does what argv[1] names:
 *
 *   twice	two damage reports of the whole screen back to back, the second
 *		before the first is answered
 *   rect	a damage report of the screen's size whose one rectangle is a
 *		pixel wider than the screen: written valid, one pixel wider in
 *		both, since the generated writer refuses a rectangle outside its
 *		report's size, then the report's width lowered to the screen's
 *   past N	descriptor 3, the window's buffer, mapped whole as erx-lvgl maps
 *		it (display/lvgl/erx_lvgl.c, map_buffer); a store to the last of
 *		the N bytes the session lent, then one to the first byte of the
 *		page past them, which faults, so the program ends with SIGSEGV
 *
 * twice and rect then read their input until it ends, since the renderer
 * stops the program. A usage the program does not know ends it with 2, input
 * or a buffer it cannot use with 3, and a store past the lent bytes that
 * does not fault with 4.
 */

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/mman.h>
#include <sys/stat.h>

#include <erx/ui_wire.h>

int	main(int, char **);

#define BUFFER_FD	3
#define EXIT_USAGE	2
#define EXIT_INPUT	3
#define EXIT_STORED	4
#define PAGE		4096

/*
 * Where a damage record's width lies: after its length word and its tag
 * (erx_ui_write_damage's layout, tools/lib/erx/abi_emit_ui_wire.rb).
 */
#define DAMAGE_WIDTH_AT	(4 + 1)

static uint8_t input[ERX_UI_OP_MAX + 4];

/* Writes bytes[0..length) whole to standard output, or ends the program. */
static void
write_all(const uint8_t *bytes, size_t length)
{
	ssize_t written;

	while (length > 0) {
		written = write(STDOUT_FILENO, bytes, length);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0)
			_exit(EXIT_INPUT);
		bytes += written;
		length -= (size_t)written;
	}
}

/* The screen record the renderer writes first, or the program ended. */
static erx_ui_record_t
screen_read(void)
{
	erx_ui_record_t record;
	size_t have = 0, used;
	ssize_t got;

	for (;;) {
		switch (erx_ui_read(input, have, &record, &used)) {
		case ERX_UI_READ_OK:
			if (record.tag != ERX_UI_SCREEN)
				_exit(EXIT_INPUT);
			return (record);
		case ERX_UI_READ_BAD:
			_exit(EXIT_INPUT);
		case ERX_UI_READ_MORE:
			break;
		}
		got = read(STDIN_FILENO, input + have, sizeof(input) - have);
		if (got < 0 && errno == EINTR)
			continue;
		if (got <= 0)
			_exit(EXIT_INPUT);
		have += (size_t)got;
	}
}

/* Reads standard input until it ends, then ends the program. */
static void
drain(void)
{
	ssize_t got;

	do
		got = read(STDIN_FILENO, input, sizeof(input));
	while (got > 0 || (got < 0 && errno == EINTR));
	_exit(0);
}

/* A damage report of one rectangle at the origin, width by height, into report. */
static size_t
damage(uint8_t *report, uint16_t width, uint16_t height)
{
	const erx_ui_rect_t whole = { .x = 0, .y = 0, .width = width,
	    .height = height };
	const size_t written = erx_ui_write_damage(report,
	    ERX_UI_DAMAGE_RECORD_MAX, width, height, &whole, 1);

	if (written == 0)
		_exit(EXIT_INPUT);
	return (written);
}

static void
twice(const erx_ui_record_t *screen)
{
	uint8_t reports[2 * ERX_UI_DAMAGE_RECORD_MAX];
	size_t first = damage(reports, screen->width, screen->height);
	size_t second = damage(reports + first, screen->width, screen->height);

	write_all(reports, first + second);
	drain();
}

static void
rect(const erx_ui_record_t *screen)
{
	uint8_t report[ERX_UI_DAMAGE_RECORD_MAX];
	size_t written;

	if (screen->width == UINT16_MAX)
		_exit(EXIT_INPUT);
	written = damage(report, screen->width + 1, screen->height);
	report[DAMAGE_WIDTH_AT] = (uint8_t)(screen->width & 0xff);
	report[DAMAGE_WIDTH_AT + 1] = (uint8_t)(screen->width >> 8);
	write_all(report, written);
	drain();
}

/* The lent bytes, argv's text, or the program ended. */
static size_t
lent_bytes(const char *text)
{
	char *end;
	uintmax_t bytes;

	errno = 0;
	bytes = strtoumax(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || bytes == 0 ||
	    bytes % PAGE != 0 || bytes > SIZE_MAX)
		_exit(EXIT_USAGE);
	return ((size_t)bytes);
}

static void
past(size_t lent)
{
	struct stat st;
	volatile uint8_t *buffer;
	void *at;

	if (fstat(BUFFER_FD, &st) != 0 || st.st_size <= 0 ||
	    (uintmax_t)st.st_size < lent || (uintmax_t)st.st_size > SIZE_MAX)
		_exit(EXIT_INPUT);
	at = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE,
	    MAP_SHARED, BUFFER_FD, 0);
	if (at == MAP_FAILED)
		_exit(EXIT_INPUT);
	buffer = at;
	buffer[lent - 1] = 0xff;
	buffer[lent] = 0xff;
	_exit(EXIT_STORED);
}

int
main(int argc, char **argv)
{
	erx_ui_record_t screen;

	if (argc == 2 && strcmp(argv[1], "twice") == 0) {
		screen = screen_read();
		twice(&screen);
	}
	if (argc == 2 && strcmp(argv[1], "rect") == 0) {
		screen = screen_read();
		rect(&screen);
	}
	if (argc == 3 && strcmp(argv[1], "past") == 0) {
		const size_t lent = lent_bytes(argv[2]);

		(void)screen_read();
		past(lent);
	}
	return (EXIT_USAGE);
}
