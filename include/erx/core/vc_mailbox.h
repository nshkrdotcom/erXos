/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_VC_MAILBOX_H
#define ERX_CORE_VC_MAILBOX_H

#include <stdint.h>

#include "erx/abi.h"

/*
 * The one mailbox routine of erx_firmware_request (docs/design-kernel.md, "Firmware
 * requests"), as a pure state machine shared by erXos's kernel and Fiasco's root backend:
 * one request at a time, the 1 s deadline from the call's start, the answer taken only from
 * the word that names the request's own buffer, and after a timeout every later call
 * answered ERX_ETIMEDOUT at once. It reads no register and no clock: the caller reads the
 * mailbox (erx/hw/vc_mbox.h) and the clock, feeds what it read, and does what the returned
 * step names. The property buffer itself is vc_property.h's.
 *
 * A request runs as:
 *
 *	step = erx_vc_mailbox_begin(&mailbox, buffer_address, now);
 *	(on ERX_VC_MAILBOX_READ_STATUS, write the request into the buffer and clean it)
 *	until step.op is ERX_VC_MAILBOX_DONE or ERX_VC_MAILBOX_CHECK:
 *		READ_STATUS: step = erx_vc_mailbox_status(&mailbox, STATUS, now)
 *		WRITE:       write step.word to WRITE, then READ_STATUS
 *		READ:        step = erx_vc_mailbox_read(&mailbox, READ)
 *	CHECK: invalidate the buffer, check it with erx_vc_answer, copy the answer out, then
 *	       erx_vc_mailbox_finish(&mailbox); the check's status is the call's.
 *	DONE:  step.status is the call's.
 *
 * The caller serializes the calls on one mailbox, and holds nothing across the wait
 * between them: a second caller's begin meets ERX_EBUSY while a request is posted or its
 * answer is being read, so the buffer is never written while the firmware or the first
 * caller still uses it.
 */

/* Where the mailbox stands. LOST is the state after a timeout, kept for the boot. */
typedef enum erx_vc_mailbox_state {
	ERX_VC_MAILBOX_IDLE = 0,
	ERX_VC_MAILBOX_POSTING,		/* claimed, waiting for room to post */
	ERX_VC_MAILBOX_POSTED,		/* posted, polling for the answer */
	ERX_VC_MAILBOX_ANSWERED,	/* the answer named the buffer; its reader holds it */
	ERX_VC_MAILBOX_LOST,
} erx_vc_mailbox_state_t;

/*
 * The routine's state: zero is an idle mailbox. message is the word posted, the buffer's
 * address with the property channel, and deadline the clock's value, in nanoseconds, at
 * which the request times out; both are meaningful only while a request is outstanding.
 */
typedef struct erx_vc_mailbox {
	erx_vc_mailbox_state_t	state;
	uint32_t		message;
	uint64_t		deadline;
} erx_vc_mailbox_t;

/* What the caller does next. */
typedef enum erx_vc_mailbox_op {
	ERX_VC_MAILBOX_DONE = 0,	/* the call ends with status */
	ERX_VC_MAILBOX_READ_STATUS,	/* read STATUS and feed it to erx_vc_mailbox_status */
	ERX_VC_MAILBOX_WRITE,		/* write word to WRITE, then read STATUS */
	ERX_VC_MAILBOX_READ,		/* read READ and feed it to erx_vc_mailbox_read */
	ERX_VC_MAILBOX_CHECK,		/* the answer is in the buffer: check it, then finish */
} erx_vc_mailbox_op_t;

typedef struct erx_vc_mailbox_step {
	erx_vc_mailbox_op_t	op;
	uint32_t		word;		/* WRITE's word */
	erx_status_t		status;		/* DONE's status */
} erx_vc_mailbox_step_t;

/*
 * Starts a request at now with the property buffer at buffer_address, the address the
 * firmware reads: after a timeout ERX_ETIMEDOUT, and beside a request outstanding
 * ERX_EBUSY, each without touching the mailbox; ERX_EINVAL for an address the mailbox
 * cannot carry (not 16-byte aligned, or above 32 bits). Otherwise the mailbox is claimed
 * and the step is READ_STATUS.
 */
erx_vc_mailbox_step_t	erx_vc_mailbox_begin(erx_vc_mailbox_t *mailbox, uint64_t buffer_address,
			    uint64_t now);

/*
 * Takes STATUS read at now. At or past the deadline the request is lost: the call ends
 * ERX_ETIMEDOUT and so does every later one. Waiting for room, FULL reads STATUS again
 * and room posts the message. Posted, EMPTY reads STATUS again and a message reads it.
 */
erx_vc_mailbox_step_t	erx_vc_mailbox_status(erx_vc_mailbox_t *mailbox, uint32_t status, uint64_t now);

/*
 * Takes a word read from READ while posted. The posted message is the answer: CHECK. Any
 * other word, another channel's message or another buffer's, is dropped: READ_STATUS.
 */
erx_vc_mailbox_step_t	erx_vc_mailbox_read(erx_vc_mailbox_t *mailbox, uint32_t word);

/* Ends the answer's reading: the mailbox is idle again. */
void			erx_vc_mailbox_finish(erx_vc_mailbox_t *mailbox);

#endif /* ERX_CORE_VC_MAILBOX_H */
