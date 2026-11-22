/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_VC_PROPERTY_H
#define ERX_CORE_VC_PROPERTY_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The mailbox core of erx_firmware_request (docs/design-kernel.md, "Firmware requests";
 * docs/design-board-sensors.md, "The kernel call"): the property buffer one row of the
 * platform record becomes, and the check of the answer the firmware leaves in it. This
 * is the pure part, shared by erXos's kernel and Fiasco's root backend: it reads no
 * hardware and holds no state. The caller owns the buffer page, its cache maintenance,
 * the posting, the poll for the answer that names this buffer, the deadline and the rule
 * after a timeout. The buffer's facts are abi/formats/vc_property.txt's.
 *
 * The buffer is little-endian words, so the core writes and reads native words on the
 * little-endian machines it serves.
 */

/* The most words a buffer holds: the header, one tag's header, its value buffer, the end tag. */
#define ERX_VC_VALUE_MAX \
	(ERX_VC_REQUEST_MAX > ERX_VC_WINDOW_MAX ? ERX_VC_REQUEST_MAX : ERX_VC_WINDOW_MAX)
#define ERX_VC_BUFFER_WORDS \
	((ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_SIZE + ERX_VC_VALUE_MAX + sizeof(uint32_t)) / sizeof(uint32_t))

/*
 * One tag's declaration: its identifier, the bytes of its request, a whole number of
 * words up to ERX_VC_REQUEST_MAX, the bytes of its answer window, a whole number of words
 * up to ERX_VC_WINDOW_MAX,
 * and the least answer it accepts. Each comes from the ABI, never from a caller.
 */
typedef struct erx_vc_tag {
	uint32_t	tag;
	uint32_t	request_bytes;
	uint32_t	window_bytes;
	uint32_t	least_bytes;
} erx_vc_tag_t;

/*
 * The declaration of tag, a member of the ABI's closed set fw_tag (abi/formats/vc_property.txt),
 * which a firmware request row names; NULL for any other word, so no caller builds a declaration.
 */
const erx_vc_tag_t	*erx_vc_tag_of(uint32_t tag);

/*
 * Writes the request for spec with the argument's request_bytes / 4 words into words:
 * the buffer's size and code 0, the tag, its value buffer's size (the larger of the
 * request and the window), a request word of 0, the argument, zeroes to the end of the
 * value buffer and the end tag. Returns the number of words written, at most
 * ERX_VC_BUFFER_WORDS.
 */
size_t	erx_vc_request(const erx_vc_tag_t *spec, const uint32_t *argument,
	    uint32_t words[ERX_VC_BUFFER_WORDS]);

/*
 * The result of an answer's check: ERX_OK with length, the bytes of the answer, at most
 * the window; or ERX_EPROTO for an answer
 * outside the interface, or ERX_ENOTSUP for a tag the firmware ignored, with length 0.
 */
typedef struct erx_vc_answer {
	erx_status_t	status;
	uint32_t	length;
} erx_vc_answer_t;

/* The value buffer's first word, where an answer's bytes start. */
#define ERX_VC_VALUE_WORD	((ERX_VC_HEADER_SIZE + ERX_VC_TAG_HEADER_SIZE) / sizeof(uint32_t))

/*
 * Checks the answer to spec's request in words, a copy of the buffer the caller read
 * once after the firmware answered, field by field: the response code, the first tag,
 * which must be spec's (another is refused, never searched past), the response bit and
 * the length against the least answer. A length past the window is cut to it. out gets
 * the answer's first length bytes from the value buffer and zeroes to its end, so nothing
 * past the window is read and nothing but the answer reaches the caller.
 */
erx_vc_answer_t	erx_vc_answer(const erx_vc_tag_t *spec, const uint32_t words[ERX_VC_BUFFER_WORDS],
	    uint8_t out[ERX_VC_WINDOW_MAX]);

#endif /* ERX_CORE_VC_PROPERTY_H */
