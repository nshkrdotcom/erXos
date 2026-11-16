/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx-raster: the glyph step's rasteriser (docs/design-desktop-programs.md,
 * "Type"), a host program linked with FreeType that no image contains.
 *
 *	erx-raster FONT SIZE GLYPH...
 *
 * loads the scalable font FONT, sets it to SIZE pixels per em, and writes
 * to standard output the coverage of each GLYPH in argument order. A GLYPH
 * is either U+XXXX, four to six upper-case hexadecimal digits, a character
 * the font's Unicode character map names, or a glyph name of the font's own (letters,
 * digits, '.' and '_'), which FreeType looks up in the font's glyph names.
 * Each glyph is loaded unhinted and rendered with FreeType's anti-aliasing
 * rasteriser, so the output is a pure function of the font file, the size
 * and FreeType's release.
 *
 * Output, every integer little-endian:
 *
 *	u16 units per em, s16 ascender, s16 descender	in font units
 *	u32 glyph count					the GLYPH count
 *	then for each GLYPH, a u8 that is 0 when the font has no such glyph,
 *	which ends that glyph's record, or 1, followed by
 *	s32 advance					26.6 pixels
 *	s32 left, s32 top				the coverage's top-left
 *							corner from the pen, in
 *							pixels, top upward
 *	u32 width, u32 rows				the coverage's size
 *	rows * width bytes				coverage, 0 to 255, row
 *							by row from the top
 *
 * A glyph that is absent is reported, not substituted: what to do with it
 * is the caller's decision. Every failure (an argument out of its form, a
 * font FreeType refuses, a glyph that is not an outline or whose coverage
 * passes MAX_SIDE, a short write) prints one diagnostic on standard error
 * and exits 1, having written nothing the caller may read as complete.
 * The font is untrusted input: FreeType parses it, and every size this
 * program takes from FreeType's results is bounded before it is used.
 */

#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freetype/freetype.h>

/* The largest SIZE, in pixels per em. */
#define MAX_SIZE	256
/* The most GLYPH arguments one run takes. */
#define MAX_GLYPHS	65536
/* The longest glyph name, in bytes. */
#define MAX_NAME	63
/* The largest width or height of one glyph's coverage, in pixels. */
#define MAX_SIDE	4096

/* What one GLYPH argument selects: a character or a glyph name. */
typedef struct glyph_request {
	const char	*name;		/* the glyph name, or NULL */
	uint32_t	 code;		/* the character, when name is NULL */
} glyph_request_t;

static void	fail(const char *, ...) __attribute__((noreturn,
		    format(printf, 1, 2)));
static bool	parse_request(const char *, glyph_request_t *);
static bool	parse_size(const char *, unsigned *);
static void	put_bytes(const void *, size_t);
static void	put_u16(uint16_t);
static void	put_u32(uint32_t);
static void	render(FT_Face, const char *, const glyph_request_t *);

int
main(int argc, char *argv[])
{
	FT_Face face;
	FT_Library library;
	FT_Error error;
	const char *font;
	glyph_request_t *requests;
	unsigned size;
	int count, i;

	if (argc < 4)
		fail("usage: erx-raster FONT SIZE GLYPH...");
	font = argv[1];
	if (!parse_size(argv[2], &size))
		fail("size is not a whole number from 1 to %d", MAX_SIZE);
	count = argc - 3;
	if (count > MAX_GLYPHS)
		fail("more than %d glyphs", MAX_GLYPHS);
	if ((requests = calloc((size_t)count, sizeof(*requests))) == NULL)
		fail("out of memory");
	for (i = 0; i < count; i++)
		if (!parse_request(argv[3 + i], &requests[i]))
			fail("glyph %d is neither U+XXXX nor a glyph name", i);

	if ((error = FT_Init_FreeType(&library)) != 0)
		fail("FreeType did not start: error %d", error);
	if ((error = FT_New_Face(library, font, 0, &face)) != 0)
		fail("%s: FreeType refused the font: error %d", font, error);
	if (!FT_IS_SCALABLE(face) || face->units_per_EM == 0)
		fail("%s: not a scalable font", font);
	if ((error = FT_Select_Charmap(face, FT_ENCODING_UNICODE)) != 0)
		fail("%s: no Unicode character map: error %d", font, error);
	if ((error = FT_Set_Pixel_Sizes(face, 0, size)) != 0)
		fail("%s: size %u refused: error %d", font, size, error);

	put_u16(face->units_per_EM);
	put_u16((uint16_t)face->ascender);
	put_u16((uint16_t)face->descender);
	put_u32((uint32_t)count);
	for (i = 0; i < count; i++)
		render(face, font, &requests[i]);
	if (fflush(stdout) != 0 || ferror(stdout))
		fail("writing the coverage: %s", strerror(errno));

	FT_Done_Face(face);
	FT_Done_FreeType(library);
	free(requests);
	return (0);
}

/*
 * One glyph's record. An absent glyph is index 0, which is also the
 * font's .notdef, so asking for .notdef by name reports it absent.
 */
static void
render(FT_Face face, const char *font, const glyph_request_t *request)
{
	const FT_Bitmap *bitmap;
	FT_GlyphSlot slot;
	FT_Error error;
	FT_UInt index;
	unsigned row;

	if (request->name != NULL)
		index = FT_HAS_GLYPH_NAMES(face) ?
		    FT_Get_Name_Index(face, request->name) : 0;
	else
		index = FT_Get_Char_Index(face, request->code);
	if (index == 0) {
		put_bytes("\0", 1);
		return;
	}

	error = FT_Load_Glyph(face, index, FT_LOAD_NO_HINTING |
	    FT_LOAD_NO_AUTOHINT | FT_LOAD_NO_BITMAP);
	if (error != 0)
		fail("%s: glyph %u did not load: error %d", font, index, error);
	slot = face->glyph;
	if (slot->format != FT_GLYPH_FORMAT_OUTLINE)
		fail("%s: glyph %u is not an outline", font, index);
	if ((error = FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL)) != 0)
		fail("%s: glyph %u did not render: error %d", font, index,
		    error);
	bitmap = &slot->bitmap;
	if (bitmap->width > MAX_SIDE || bitmap->rows > MAX_SIDE)
		fail("%s: glyph %u is larger than %d pixels", font, index,
		    MAX_SIDE);
	if (bitmap->rows > 0 && bitmap->width > 0 &&
	    (bitmap->pixel_mode != FT_PIXEL_MODE_GRAY ||
	    bitmap->num_grays != 256 || bitmap->pitch < 0 ||
	    (unsigned)bitmap->pitch < bitmap->width))
		fail("%s: glyph %u has no 8-bit coverage", font, index);
	if (slot->advance.x < INT32_MIN || slot->advance.x > INT32_MAX)
		fail("%s: glyph %u advances out of range", font, index);

	put_bytes("\1", 1);
	put_u32((uint32_t)(int32_t)slot->advance.x);
	put_u32((uint32_t)(int32_t)slot->bitmap_left);
	put_u32((uint32_t)(int32_t)slot->bitmap_top);
	put_u32(bitmap->width);
	put_u32(bitmap->rows);
	for (row = 0; row < bitmap->rows && bitmap->width > 0; row++)
		put_bytes(bitmap->buffer + (size_t)row * (size_t)bitmap->pitch,
		    bitmap->width);
}

/* U+XXXX, at most U+10FFFF, or a glyph name. */
static bool
parse_request(const char *text, glyph_request_t *request)
{
	unsigned long code;
	char *end;
	size_t length;

	length = strlen(text);
	if (strncmp(text, "U+", 2) == 0) {
		if (length < 6 || length > 8 ||
		    strspn(text + 2, "0123456789ABCDEF") != length - 2)
			return (false);
		code = strtoul(text + 2, &end, 16);
		if (*end != '\0' || code > 0x10FFFF)
			return (false);
		request->name = NULL;
		request->code = (uint32_t)code;
		return (true);
	}
	if (length == 0 || length > MAX_NAME || strspn(text,
	    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	    "0123456789._") != length)
		return (false);
	request->name = text;
	request->code = 0;
	return (true);
}

static bool
parse_size(const char *text, unsigned *size)
{
	unsigned long value;
	char *end;

	if (text[0] < '1' || text[0] > '9')
		return (false);
	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno != 0 || *end != '\0' || value > MAX_SIZE)
		return (false);
	*size = (unsigned)value;
	return (true);
}

static void
put_bytes(const void *bytes, size_t length)
{
	if (fwrite(bytes, 1, length, stdout) != length)
		fail("writing the coverage: %s", strerror(errno));
}

static void
put_u16(uint16_t value)
{
	unsigned char bytes[2];

	bytes[0] = value & 0xff;
	bytes[1] = value >> 8;
	put_bytes(bytes, sizeof(bytes));
}

static void
put_u32(uint32_t value)
{
	unsigned char bytes[4];

	bytes[0] = value & 0xff;
	bytes[1] = (value >> 8) & 0xff;
	bytes[2] = (value >> 16) & 0xff;
	bytes[3] = value >> 24;
	put_bytes(bytes, sizeof(bytes));
}

static void
fail(const char *format, ...)
{
	va_list args;

	fputs("erx-raster: ", stderr);
	va_start(args, format);
	vfprintf(stderr, format, args);
	va_end(args);
	fputc('\n', stderr);
	exit(1);
}
