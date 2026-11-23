/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SERVICE_WIRE_H
#define ERX_FIASCO_SERVICE_WIRE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The root service's decoder (docs/design-fiasco.md, "The root service"): what a
 * received message is, from its gate label, tag and message words. It reads
 * nothing else, and every word it sees is the sender's.
 */

#define ERX_FIASCO_THREADS_MAX		128u
/* Fiasco's fault protocols; service.c pins these to Fiasco's own. */
#define ERX_FIASCO_WIRE_PAGE_FAULT	(-2)
#define ERX_FIASCO_WIRE_EXCEPTION	(-5)
/* Each fault's words, all of them: its handler reads them without looking again. service.c pins the
 * exception's to Fiasco's, and the native_crash suite runs both. */
#define ERX_FIASCO_WIRE_PAGE_FAULT_WORDS	2u
#define ERX_FIASCO_WIRE_EXCEPTION_WORDS	40u
/* The gate label holds the task's index above the sender's rights. */
#define ERX_FIASCO_WIRE_LABEL_SHIFT	2u
/*
 * The longest request, in words: domain_space_create's layout. Each case of the decoder's
 * word table fails to build for a layout longer than this, so a longer request added to the
 * ABI moves this to its own layout.
 */
#define ERX_FIASCO_WIRE_WORDS_MAX	((uint32_t)(sizeof(erx_fiasco_domain_space_create_request_t) / sizeof(uint64_t)))

typedef enum erx_fiasco_wire_kind {
	ERX_FIASCO_WIRE_DROP = 1,	/* no live task: its answer reaches no running thread */
	ERX_FIASCO_WIRE_REFUSE,		/* reply with status */
	ERX_FIASCO_WIRE_REQUEST,
	ERX_FIASCO_WIRE_FAULT_PAGE,
	ERX_FIASCO_WIRE_FAULT_EXCEPTION
} erx_fiasco_wire_kind_t;

typedef struct erx_fiasco_wire_input {
	uint64_t	 label;
	int64_t		 tag_label;
	uint32_t	 words;		/* the tag's count; mr holds at least this many */
	bool		(*task_live)(uint32_t task);	/* whether a gate's label names a live task */
	const uint64_t	*mr;
} erx_fiasco_wire_input_t;

typedef struct erx_fiasco_wire_decoded {
	erx_fiasco_wire_kind_t kind;
	int32_t		 status;	/* for REFUSE */
	uint32_t	 task;
	uint32_t	 call;		/* for REQUEST: an erx_fiasco_call_t */
	uint32_t	 caller;	/* for REQUEST: below ERX_FIASCO_THREADS_MAX */
	uint64_t	 request[ERX_FIASCO_WIRE_WORDS_MAX];	/* for REQUEST */
} erx_fiasco_wire_decoded_t;

erx_fiasco_wire_decoded_t erx_fiasco_wire_decode(const erx_fiasco_wire_input_t *);

/* How many words a request of this number has, or 0 when it has none. */
uint32_t erx_fiasco_wire_words(int64_t);

#endif /* ERX_FIASCO_SERVICE_WIRE_H */
