/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The mailbox answer check (erx_vc_answer in include/erx/core/vc_property.h) against a
 * hostile firmware, whose answer is whatever it wrote into the property buffer. The input
 * is four bytes that choose the tag's declaration, then the buffer's words, zero past the
 * input's end: byte 0 even takes NOTIFY_XHCI_RESET's declaration, odd with bit 1 set
 * SET_GPIO_STATE's, and odd with bit 1 clear a model one whose window is byte 1, whose
 * least answer is byte 2 and whose request is byte 3, each a number of words cut to what a
 * declaration may hold.
 *
 * The buffer lies in an allocation of exactly ERX_VC_BUFFER_WORDS words, so a read past it
 * is AddressSanitizer's. The harness checks the result against a model written from the
 * interface (abi/formats/vc_property.txt): the response code, the first tag, the response
 * word and the least answer decide the status in that order, the first value word in place
 * of the least answer on a tag the firmware answers there, the length is the firmware's cut to the
 * window, out holds the value buffer's first length bytes and zeroes to its end.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/vc_property.h"

#define DECLARATION_BYTES	4u
#define WORD_BYTES		sizeof(uint32_t)

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void
check(bool condition)
{
	if (!condition)
		abort();
}

/* A declaration erx_vc_tag_t allows: whole words, the least answer within the window. */
static erx_vc_tag_t
declaration(const uint8_t choice[DECLARATION_BYTES])
{
	const uint32_t window_words = choice[1] % (ERX_VC_WINDOW_MAX / WORD_BYTES + 1);

	if ((choice[0] & 1u) == 0)
		return (*erx_vc_tag_of(ERX_FW_TAG_NOTIFY_XHCI_RESET));
	if ((choice[0] & 2u) != 0)
		return (*erx_vc_tag_of(ERX_FW_TAG_SET_GPIO_STATE));
	return ((erx_vc_tag_t){
		.tag = ERX_FW_TAG_NOTIFY_XHCI_RESET,
		.request_bytes = choice[3] % (ERX_VC_REQUEST_MAX / WORD_BYTES + 1) * WORD_BYTES,
		.window_bytes = window_words * WORD_BYTES,
		.least_bytes = choice[2] % (window_words + 1) * WORD_BYTES,
	});
}

/* The status and length the interface gives words for spec. */
static erx_vc_answer_t
model(const erx_vc_tag_t *spec, const uint32_t *words)
{
	const uint32_t indicator = words[(ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_OFF_INDICATOR) / WORD_BYTES];
	const uint32_t length = indicator & 0x7fffffffu;

	if (words[ERX_VC_HEADER_OFF_CODE / WORD_BYTES] != ERX_VC_CODE_SUCCESS ||
	    words[(ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_OFF_TAG) / WORD_BYTES] != spec->tag)
		return ((erx_vc_answer_t){ .status = ERX_EPROTO, .length = 0 });
	if (spec->result_word && (indicator == 0 || (indicator & 0x80000000u) != 0))
		return ((erx_vc_answer_t){ .status = words[ERX_VC_VALUE_WORD] == 0 ? ERX_OK : ERX_ENOTSUP, .length = 0 });
	if ((indicator & 0x80000000u) == 0)
		return ((erx_vc_answer_t){ .status = ERX_ENOTSUP, .length = 0 });
	if (length < spec->least_bytes)
		return ((erx_vc_answer_t){ .status = ERX_EPROTO, .length = 0 });
	return ((erx_vc_answer_t){
		.status = ERX_OK,
		.length = length < spec->window_bytes ? length : spec->window_bytes,
	});
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const size_t buffer_bytes = ERX_VC_BUFFER_WORDS * WORD_BYTES;
	uint8_t out[ERX_VC_WINDOW_MAX];
	erx_vc_answer_t answer, expected;
	erx_vc_tag_t spec;
	uint32_t *words;

	if (size < DECLARATION_BYTES)
		return (0);
	spec = declaration(data);
	words = calloc(ERX_VC_BUFFER_WORDS, WORD_BYTES);
	check(words != NULL);
	memcpy(words, data + DECLARATION_BYTES,
	    size - DECLARATION_BYTES < buffer_bytes ? size - DECLARATION_BYTES : buffer_bytes);
	memset(out, 0xa5, sizeof(out));

	answer = erx_vc_answer(&spec, words, out);
	expected = model(&spec, words);
	check(answer.status == expected.status && answer.length == expected.length);
	check(answer.length <= spec.window_bytes);
	check(memcmp(out, (const uint8_t *)words + ERX_VC_VALUE_WORD * WORD_BYTES, answer.length) == 0);
	for (size_t at = answer.length; at < sizeof(out); at++)
		check(out[at] == 0);
	free(words);
	return (0);
}
