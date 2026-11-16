/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Asks LVGL's own font code for each code point of its arguments in the
 * body role's generated LVGL font: lv_font_get_glyph_dsc with the next
 * argument as the following character (0 after the last), and the raw
 * bitmap from lv_font_get_glyph_static_bitmap. Prints one line a code point,
 * "ADVANCE BOX_W BOX_H OFS_X OFS_Y BITMAP", BITMAP its bytes in hex ("-"
 * for none), or "absent" when the font lacks it. Used by
 * test/host/kerning_test.rb.
 *
 * usage: lvgl_kern_probe CODE_POINT..., each in decimal
 */

#include <stdio.h>
#include <stdlib.h>

#include "lvgl.h"

extern const lv_font_t erx_lvgl_font_body;

static void
probe(uint32_t letter, uint32_t next)
{
	lv_font_glyph_dsc_t dsc;
	const uint8_t *bitmap = NULL;
	uint32_t size, i;

	if (!lv_font_get_glyph_dsc(&erx_lvgl_font_body, &dsc, letter, next)) {
		printf("absent\n");
		return;
	}
	printf("%u %u %u %d %d ", (unsigned)dsc.adv_w, (unsigned)dsc.box_w,
	    (unsigned)dsc.box_h, (int)dsc.ofs_x, (int)dsc.ofs_y);
	size = (uint32_t)dsc.box_w * dsc.box_h;
	if (size != 0)
		bitmap = lv_font_get_glyph_static_bitmap(&dsc);
	if (bitmap == NULL)
		printf("-");
	for (i = 0; bitmap != NULL && i < size; i++)
		printf("%02x", bitmap[i]);
	printf("\n");
}

int
main(int argc, char **argv)
{
	int i;

	for (i = 1; i < argc; i++)
		probe((uint32_t)strtoul(argv[i], NULL, 10),
		    i + 1 < argc ? (uint32_t)strtoul(argv[i + 1], NULL, 10) : 0);
	return 0;
}
