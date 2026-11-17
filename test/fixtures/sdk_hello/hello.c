/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The SDK's hello program (test/host/sdk_test.rb; docs/design-packaging.md,
 * "The SDK"), built with the SDK alone: it allocates a one-pixel image of a
 * color that replicates over any rectangle, draws it over a rectangle of
 * its window, image 0, flushes, and reads one key from /dev/kbd.  The draw
 * messages are laid out with erx/draw.h, generated from the protocol's
 * format.  It ends with 0, or with the step that failed.
 */

#include <erx/draw.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define FILL_ID	1
/* draw(3)'s r8g8b8: CHAN3(CRed, 8, CGreen, 8, CBlue, 8). */
#define RGB24	0x081828u
#define COLOR	0x3366ccffu

static void
put_rect(uint8_t *at, int32_t x0, int32_t y0, int32_t x1, int32_t y1)
{
	erx_draw_put32(at, (uint32_t)x0);
	erx_draw_put32(at + 4, (uint32_t)y0);
	erx_draw_put32(at + 8, (uint32_t)x1);
	erx_draw_put32(at + 12, (uint32_t)y1);
}

int
main(void)
{
	uint8_t alloc[ERX_DRAW_ALLOC_SIZE], draw[ERX_DRAW_DRAW_SIZE];
	uint8_t flush[ERX_DRAW_FLUSH_SIZE];
	char key[8];
	int fd, kbd;

	memset(alloc, 0, sizeof(alloc));
	alloc[0] = ERX_DRAW_ALLOC;
	erx_draw_put32(alloc + ERX_DRAW_ALLOC_ID, FILL_ID);
	erx_draw_put32(alloc + ERX_DRAW_ALLOC_CHAN, RGB24);
	alloc[ERX_DRAW_ALLOC_REPL] = 1;
	put_rect(alloc + ERX_DRAW_ALLOC_R, 0, 0, 1, 1);
	put_rect(alloc + ERX_DRAW_ALLOC_CLIPR, -0x3fffffff, -0x3fffffff,
	    0x3fffffff, 0x3fffffff);
	erx_draw_put32(alloc + ERX_DRAW_ALLOC_COLOR, COLOR);

	memset(draw, 0, sizeof(draw));
	draw[0] = ERX_DRAW_DRAW;
	erx_draw_put32(draw + ERX_DRAW_DRAW_DST, 0);
	erx_draw_put32(draw + ERX_DRAW_DRAW_SRC, FILL_ID);
	erx_draw_put32(draw + ERX_DRAW_DRAW_MASK, FILL_ID);
	put_rect(draw + ERX_DRAW_DRAW_R, 16, 16, 112, 80);

	flush[0] = ERX_DRAW_FLUSH;

	if ((fd = open("/dev/draw", O_RDWR)) < 0)
		return (1);
	if (write(fd, alloc, sizeof(alloc)) != (ssize_t)sizeof(alloc) ||
	    write(fd, draw, sizeof(draw)) != (ssize_t)sizeof(draw) ||
	    write(fd, flush, sizeof(flush)) != (ssize_t)sizeof(flush))
		return (2);
	if ((kbd = open("/dev/kbd", O_RDONLY)) < 0)
		return (3);
	if (read(kbd, key, sizeof(key)) <= 0)
		return (4);
	close(kbd);
	close(fd);
	return (0);
}
