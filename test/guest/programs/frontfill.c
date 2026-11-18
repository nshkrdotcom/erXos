/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kiosk suite's stand-in for Doom (tools/lib/erx/kiosk.rb, the front
 * cell): a program root starts from rc that opens /dev/draw, /dev/ctl and
 * /dev/kbd in that order, as Doom's platform layer does, so its handler
 * opens its window at the first of them (docs/design-programs.md, "A window
 * at the first open of /dev/draw").  It reads image 0's rectangle from ctl
 * and then, every FRAME_NS, fills the window with the next of COLORS
 * one-pixel replicated images through an opaque mask and flushes, so any
 * two frames less than COLORS frames apart differ.  After its first frame
 * it writes
 * "frontfill: drawing" to standard output, and it runs until a signal ends
 * it.  The draw messages are laid out with erx/draw.h, generated from the
 * protocol's format.  It ends with the step that failed.
 */

#include <erx/draw.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define COLORS		16
#define FRAME_NS	250000000L
/* draw(3)'s r8g8b8: CHAN3(CRed, 8, CGreen, 8, CBlue, 8). */
#define RGB24		0x081828u
/*
 * ctl's text: twelve fields each right-aligned in 11 characters and followed
 * by a blank, draw(3)'s client id, image id, channel and replicate bit, then
 * image 0's rectangle and its clip rectangle (docs/design-display.md, "The
 * connection's files"; erx_draw_core:ctl/1).  CTL_RECT is the rectangle's
 * first field, counted from 0.
 */
#define CTL_SIZE	144
#define CTL_FIELD	12
#define CTL_RECT	4
/* The mask, opaque white, so a fill replaces what the window held. */
#define MASK_ID		(COLORS + 1)
#define OPAQUE		0xffffffffu
#define DRAWING		"frontfill: drawing\n"

int	main(void);

static void
put_rect(uint8_t *at, const int32_t r[4])
{
	for (int i = 0; i < 4; i++)
		erxdraw_put32(at + 4 * i, (uint32_t)r[i]);
}

static int
put(int fd, const void *bytes, size_t length)
{
	return (write(fd, bytes, length) == (ssize_t)length ? 0 : -1);
}

/* Image 0's rectangle, from ctl's text in r. */
static int
read_rect(int ctl, int32_t r[4])
{
	char text[CTL_SIZE + 1], *end;

	if (read(ctl, text, CTL_SIZE) != CTL_SIZE)
		return (-1);
	text[CTL_SIZE] = '\0';
	for (int i = 0; i < 4; i++) {
		const char *field = text + CTL_FIELD * (CTL_RECT + i);
		const long value = strtol(field, &end, 10);

		if (end == field || *end != ' ' || value < INT32_MIN ||
		    value > INT32_MAX)
			return (-1);
		r[i] = (int32_t)value;
	}
	return (0);
}

/* Allocates image id, one pixel of color replicated over any rectangle. */
static int
alloc_color(int fd, uint32_t id, uint32_t color)
{
	static const int32_t pixel[4] = { 0, 0, 1, 1 };
	static const int32_t everywhere[4] = { -0x3fffffff, -0x3fffffff,
	    0x3fffffff, 0x3fffffff };
	uint8_t alloc[ERX_DRAW_ALLOC_SIZE];

	memset(alloc, 0, sizeof(alloc));
	alloc[0] = ERX_DRAW_ALLOC;
	erxdraw_put32(alloc + ERX_DRAW_ALLOC_ID, id);
	erxdraw_put32(alloc + ERX_DRAW_ALLOC_CHAN, RGB24);
	alloc[ERX_DRAW_ALLOC_REPL] = 1;
	put_rect(alloc + ERX_DRAW_ALLOC_R, pixel);
	put_rect(alloc + ERX_DRAW_ALLOC_CLIPR, everywhere);
	erxdraw_put32(alloc + ERX_DRAW_ALLOC_COLOR, color);
	return (put(fd, alloc, sizeof(alloc)));
}

/* Color i of COLORS, as 0xRRGGBBAA, each of red, green and blue its own step. */
static uint32_t
color(uint32_t i)
{
	return ((i * 16u) << 24 | (255u - i * 16u) << 16 |
	    ((i * 48u) & 0xffu) << 8 | 0xffu);
}

/* Fills rectangle r of image 0 with image id through the mask and flushes, in one write. */
static int
fill(int fd, uint32_t id, const int32_t r[4])
{
	uint8_t frame[ERX_DRAW_DRAW_SIZE + ERX_DRAW_FLUSH_SIZE];

	memset(frame, 0, sizeof(frame));
	frame[0] = ERX_DRAW_DRAW;
	erxdraw_put32(frame + ERX_DRAW_DRAW_DST, 0);
	erxdraw_put32(frame + ERX_DRAW_DRAW_SRC, id);
	erxdraw_put32(frame + ERX_DRAW_DRAW_MASK, MASK_ID);
	put_rect(frame + ERX_DRAW_DRAW_R, r);
	frame[ERX_DRAW_DRAW_SIZE] = ERX_DRAW_FLUSH;
	return (put(fd, frame, sizeof(frame)));
}

int
main(void)
{
	const struct timespec frame = { 0, FRAME_NS };
	int32_t r[4];
	int fd, ctl, kbd;

	if ((fd = open("/dev/draw", O_RDWR)) < 0)
		return (1);
	if ((ctl = open("/dev/ctl", O_RDONLY)) < 0 || read_rect(ctl, r) != 0)
		return (2);
	if ((kbd = open("/dev/kbd", O_RDONLY)) < 0)
		return (3);
	for (uint32_t i = 0; i < COLORS; i++)
		if (alloc_color(fd, i + 1, color(i)) != 0)
			return (4);
	if (alloc_color(fd, MASK_ID, OPAQUE) != 0)
		return (4);
	for (uint32_t n = 0;; n++) {
		if (fill(fd, n % COLORS + 1, r) != 0)
			return (5);
		if (n == 0 && put(1, DRAWING, strlen(DRAWING)) != 0)
			return (6);
		nanosleep(&frame, NULL);
	}
}
