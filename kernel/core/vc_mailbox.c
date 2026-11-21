/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/core/vc_mailbox.h"
#include "erx/hw/vc_mbox.h"

/* The low bits the channel takes, so a buffer's address must leave them clear. */
#define CHANNEL_MASK	UINT64_C(0xf)

static erx_vc_mailbox_step_t
done(erx_status_t status)
{
	return ((erx_vc_mailbox_step_t){ .op = ERX_VC_MAILBOX_DONE, .status = status });
}

static erx_vc_mailbox_step_t
next(erx_vc_mailbox_op_t op, uint32_t message)
{
	return ((erx_vc_mailbox_step_t){ .op = op, .message = message, .status = ERX_OK });
}

/* The message that posts the buffer at address on the property channel, if it can carry it. */
static bool
message_for(uint64_t address, uint32_t *message)
{
	uint32_t channel = 0;

	return ((address & CHANNEL_MASK) == 0 && address <= UINT32_MAX &&
	    erx_vc_mbox_write_channel_set(0, ERX_VC_MBOX_WRITE_CHANNEL_PROPERTY, &channel) &&
	    erx_vc_mbox_write_data_set(channel, (uint32_t)(address >> 4), message));
}

/* At or past the deadline the request is lost, and the buffer left to the firmware for the boot. */
static bool
expired(erx_vc_mailbox_t *mailbox, uint64_t now)
{
	if (now < mailbox->deadline)
		return (false);
	*mailbox = (erx_vc_mailbox_t){ .state = ERX_VC_MAILBOX_LOST };
	return (true);
}

erx_vc_mailbox_step_t
erx_vc_mailbox_begin(erx_vc_mailbox_t *mailbox, uint64_t buffer_address, uint64_t now)
{
	uint32_t message;

	switch (mailbox->state) {
	case ERX_VC_MAILBOX_LOST:
		return (done(ERX_ETIMEDOUT));
	case ERX_VC_MAILBOX_POSTING:
	case ERX_VC_MAILBOX_POSTED:
	case ERX_VC_MAILBOX_ANSWERED:
		return (done(ERX_EBUSY));
	case ERX_VC_MAILBOX_IDLE:
		break;
	}
	if (!message_for(buffer_address, &message))
		return (done(ERX_EINVAL));
	*mailbox = (erx_vc_mailbox_t){
		.state = ERX_VC_MAILBOX_POSTING,
		.message = message,
		.deadline = now > UINT64_MAX - ERX_VC_DEADLINE_NS ? UINT64_MAX : now + ERX_VC_DEADLINE_NS,
	};
	return (next(ERX_VC_MAILBOX_FILL, 0));
}

erx_vc_mailbox_step_t
erx_vc_mailbox_status(erx_vc_mailbox_t *mailbox, uint32_t status_reg, uint64_t now)
{
	if (mailbox->state != ERX_VC_MAILBOX_POSTING && mailbox->state != ERX_VC_MAILBOX_POSTED)
		return (done(ERX_EINVAL));
	if (expired(mailbox, now))
		return (done(ERX_ETIMEDOUT));
	if (erx_vc_mbox_status_empty_get(status_reg) == 0)
		return (next(ERX_VC_MAILBOX_READ, 0));
	if (mailbox->state == ERX_VC_MAILBOX_POSTED)
		return (next(ERX_VC_MAILBOX_READ_STATUS, 0));
	/* Drained: nothing older than this request can be taken for its answer. */
	mailbox->state = ERX_VC_MAILBOX_POSTED;
	return (next(ERX_VC_MAILBOX_WRITE, mailbox->message));
}

erx_vc_mailbox_step_t
erx_vc_mailbox_read(erx_vc_mailbox_t *mailbox, uint32_t read_reg, uint64_t now)
{
	if (mailbox->state != ERX_VC_MAILBOX_POSTING && mailbox->state != ERX_VC_MAILBOX_POSTED)
		return (done(ERX_EINVAL));
	if (expired(mailbox, now))
		return (done(ERX_ETIMEDOUT));
	if (mailbox->state == ERX_VC_MAILBOX_POSTING || read_reg != mailbox->message)
		return (next(ERX_VC_MAILBOX_READ_STATUS, 0));
	mailbox->state = ERX_VC_MAILBOX_ANSWERED;
	return (next(ERX_VC_MAILBOX_CHECK, 0));
}

erx_vc_answer_t
erx_vc_mailbox_answer(erx_vc_mailbox_t *mailbox, const erx_vc_tag_t *spec,
    const uint32_t words[ERX_VC_BUFFER_WORDS], uint8_t out[ERX_VC_WINDOW_MAX])
{
	if (mailbox->state != ERX_VC_MAILBOX_ANSWERED) {
		for (uint32_t at = 0; at < ERX_VC_WINDOW_MAX; at++)
			out[at] = 0;
		return ((erx_vc_answer_t){ .status = ERX_EINVAL, .length = 0 });
	}
	*mailbox = (erx_vc_mailbox_t){ .state = ERX_VC_MAILBOX_IDLE };
	return (erx_vc_answer(spec, words, out));
}
