/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/vc_property.h"

/* Word indices of the buffer, from the layouts' byte offsets. */
#define WORD(bytes)	((bytes) / sizeof(uint32_t))
#define AT_SIZE		WORD(ERX_VC_HEADER_OFF_SIZE)
#define AT_CODE		WORD(ERX_VC_HEADER_OFF_CODE)
#define AT_TAG		WORD(ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_OFF_TAG)
#define AT_VALUE_SIZE	WORD(ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_OFF_VALUE_SIZE)
#define AT_INDICATOR	WORD(ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_OFF_INDICATOR)

_Static_assert(ERX_VC_HEADER_SIZE % sizeof(uint32_t) == 0 && ERX_VC_TAG_HEADER_SIZE % sizeof(uint32_t) == 0,
    "the headers are whole words");
_Static_assert(ERX_VC_REQUEST_MAX % sizeof(uint32_t) == 0 && ERX_VC_WINDOW_MAX % sizeof(uint32_t) == 0,
    "requests and windows are whole words");
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "the buffer's words are little-endian, as the machine's");
_Static_assert(ERX_VC_NOTIFY_XHCI_RESET_REQUEST % sizeof(uint32_t) == 0 &&
    ERX_VC_NOTIFY_XHCI_RESET_WINDOW % sizeof(uint32_t) == 0 &&
    ERX_VC_NOTIFY_XHCI_RESET_REQUEST <= ERX_VC_ROW_WORDS * sizeof(uint32_t) &&
    ERX_VC_NOTIFY_XHCI_RESET_WINDOW <= ERX_VC_WINDOW_MAX &&
    ERX_VC_NOTIFY_XHCI_RESET_LEAST <= ERX_VC_NOTIFY_XHCI_RESET_WINDOW,
    "NOTIFY_XHCI_RESET's declaration fits the buffer");
_Static_assert(ERX_VC_SET_GPIO_STATE_REQUEST % sizeof(uint32_t) == 0 &&
    ERX_VC_SET_GPIO_STATE_REQUEST >= sizeof(uint32_t) &&
    ERX_VC_SET_GPIO_STATE_REQUEST <= ERX_VC_ROW_WORDS * sizeof(uint32_t) &&
    ERX_VC_SET_GPIO_STATE_WINDOW == 0 && ERX_VC_SET_GPIO_STATE_LEAST == 0,
    "SET_GPIO_STATE's declaration fits the buffer, its answer word within its request and its window empty");

static const erx_vc_tag_t vc_notify_xhci_reset = {
	.tag = ERX_FW_TAG_NOTIFY_XHCI_RESET,
	.request_bytes = ERX_VC_NOTIFY_XHCI_RESET_REQUEST,
	.window_bytes = ERX_VC_NOTIFY_XHCI_RESET_WINDOW,
	.least_bytes = ERX_VC_NOTIFY_XHCI_RESET_LEAST,
	.result_word = ERX_VC_NOTIFY_XHCI_RESET_RESULT_WORD != 0,
};

static const erx_vc_tag_t vc_set_gpio_state = {
	.tag = ERX_FW_TAG_SET_GPIO_STATE,
	.request_bytes = ERX_VC_SET_GPIO_STATE_REQUEST,
	.window_bytes = ERX_VC_SET_GPIO_STATE_WINDOW,
	.least_bytes = ERX_VC_SET_GPIO_STATE_LEAST,
	.result_word = ERX_VC_SET_GPIO_STATE_RESULT_WORD != 0,
};

const erx_vc_tag_t *
erx_vc_tag_of(uint32_t tag)
{
	switch (tag) {
	case ERX_FW_TAG_NOTIFY_XHCI_RESET:
		return (&vc_notify_xhci_reset);
	case ERX_FW_TAG_SET_GPIO_STATE:
		return (&vc_set_gpio_state);
	default:
		return (NULL);
	}
}

size_t
erx_vc_request(const erx_vc_tag_t *spec, const uint32_t *argument, uint32_t words[ERX_VC_BUFFER_WORDS])
{
	const uint32_t value_bytes = spec->request_bytes > spec->window_bytes ? spec->request_bytes : spec->window_bytes;
	const size_t value_words = value_bytes / sizeof(uint32_t);
	const size_t request_words = spec->request_bytes / sizeof(uint32_t);
	size_t at = ERX_VC_VALUE_WORD;

	words[AT_CODE] = ERX_VC_CODE_REQUEST;
	words[AT_TAG] = spec->tag;
	words[AT_VALUE_SIZE] = (uint32_t)(value_words * sizeof(uint32_t));
	words[AT_INDICATOR] = 0;
	for (size_t word = 0; word < value_words; word++)
		words[at++] = word < request_words ? argument[word] : 0;
	words[at++] = ERX_VC_END_TAG;
	words[AT_SIZE] = (uint32_t)(at * sizeof(uint32_t));
	return (at);
}

erx_vc_answer_t
erx_vc_answer(const erx_vc_tag_t *spec, const uint32_t words[ERX_VC_BUFFER_WORDS], uint8_t out[ERX_VC_WINDOW_MAX])
{
	const uint8_t *const value = (const uint8_t *)&words[ERX_VC_VALUE_WORD];
	erx_vc_answer_t answer;
	const uint32_t code = words[AT_CODE];
	const uint32_t tag = words[AT_TAG];
	const uint32_t indicator = words[AT_INDICATOR];
	/* The firmware answered: bit 31, or a word of 0 on a tag it answers in its first value word. */
	const bool answered = erx_vc_tag_header_indicator_response_get(indicator) != 0 ||
	    (spec->result_word && indicator == 0);
	uint32_t length;

	if (code != ERX_VC_CODE_SUCCESS || tag != spec->tag)
		answer = (erx_vc_answer_t){ .status = ERX_EPROTO, .length = 0 };
	else if (!answered)
		answer = (erx_vc_answer_t){ .status = ERX_ENOTSUP, .length = 0 };
	else if (spec->result_word)	/* performed only if the first value word, within the request, reads 0 */
		answer = (erx_vc_answer_t){
			.status = words[ERX_VC_VALUE_WORD] == 0 ? ERX_OK : ERX_ENOTSUP,
			.length = 0,
		};
	else if ((length = erx_vc_tag_header_indicator_length_get(indicator)) < spec->least_bytes)
		answer = (erx_vc_answer_t){ .status = ERX_EPROTO, .length = 0 };
	else
		answer = (erx_vc_answer_t){
			.status = ERX_OK,
			.length = length < spec->window_bytes ? length : spec->window_bytes,
		};
	/* The answer's bytes, nothing past them read, and zeroes after them on every result. */
	for (uint32_t at = 0; at < ERX_VC_WINDOW_MAX; at++)
		out[at] = at < answer.length ? value[at] : 0;
	return (answer);
}
