/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/vc_property.c for test/host/vc_property_test.rb. Each line of
 * standard input is one request and gets one line of answer, every word in hexadecimal:
 *
 *   request TAG ARG    -> request W..., the buffer the core writes for TAG with the
 *                         one-word argument ARG
 *   answer TAG W...    -> answer STATUS N BYTES, the core's check of the buffer W... as
 *                         the firmware left it, for TAG; STATUS in decimal, BYTES the
 *                         answer the core copies, its window's bytes in memory order
 *
 *   tag WORD           -> tag 1 when WORD is a member of fw_tag with a declaration, else tag 0
 *
 * TAG is notify, the ABI's NOTIFY_XHCI_RESET, or model, a tag of this driver's own with
 * a one-word request, an 8-byte window and a least answer of 4, which reaches the parts
 * of the check an empty window leaves out.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/vc_property.h"

static const erx_vc_tag_t model = {
	.tag = 0x00012345u, .request_bytes = 4, .window_bytes = 8, .least_bytes = 4,
};

static const erx_vc_tag_t *
tag_named(const char *name)
{
	if (name != NULL && strcmp(name, "notify") == 0)
		return (erx_vc_tag_of(ERX_FW_TAG_NOTIFY_XHCI_RESET));
	if (name != NULL && strcmp(name, "model") == 0)
		return (&model);
	return (NULL);
}

int
main(void)
{
	char line[1024];

	while (fgets(line, sizeof(line), stdin) != NULL) {
		const char *const verb = strtok(line, " \n");

		if (verb != NULL && strcmp(verb, "tag") == 0) {
			const char *const tag_word = strtok(NULL, " \n");

			if (tag_word == NULL)
				return (2);
			printf("tag %d\n", erx_vc_tag_of((uint32_t)strtoul(tag_word, NULL, 16)) != NULL);
			continue;
		}
		const erx_vc_tag_t *const tag = tag_named(strtok(NULL, " \n"));
		uint32_t words[ERX_VC_BUFFER_WORDS] = { 0 };
		size_t nwords = 0;
		const char *word;

		if (verb == NULL || tag == NULL)
			return (2);
		while ((word = strtok(NULL, " \n")) != NULL && nwords < ERX_VC_BUFFER_WORDS)
			words[nwords++] = (uint32_t)strtoul(word, NULL, 16);
		if (strcmp(verb, "request") == 0 && nwords == 1) {
			/* The argument's one word, with a poison word behind it that a read past it shows. */
			const struct { uint32_t value[1]; uint32_t poison; } argument = { { words[0] }, 0xdeadbeefu };
			uint32_t buffer[ERX_VC_BUFFER_WORDS];
			const size_t written = erx_vc_request(tag, argument.value, buffer);

			printf("request");
			for (size_t at = 0; at < written; at++)
				printf(" %08" PRIx32, buffer[at]);
			printf("\n");
		} else if (strcmp(verb, "answer") == 0) {
			uint8_t out[ERX_VC_WINDOW_MAX];
			const erx_vc_answer_t answer = erx_vc_answer(tag, words, out);
			size_t nonzero = 0;

			printf("answer %" PRId32 " %" PRIu32 " ", answer.status, answer.length);
			for (size_t at = 0; at < tag->window_bytes; at++)
				printf("%02x", out[at]);
			for (size_t at = tag->window_bytes; at < ERX_VC_WINDOW_MAX; at++)
				nonzero += out[at] != 0;
			printf(nonzero == 0 ? "\n" : " past-window\n");
		} else
			return (2);
	}
	return (0);
}
