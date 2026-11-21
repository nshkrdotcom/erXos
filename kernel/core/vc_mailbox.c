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
next(erx_vc_mailbox_op_t op, uint32_t word)
{
	return ((erx_vc_mailbox_step_t){ .op = op, .word = word, .status = ERX_OK });
}

/* The message that posts the buffer at address on the property channel, if it can carry it. */
static bool
message_for(uint64_t address, uint32_t *message)
{
	uint32_t word = 0;

	return ((address & CHANNEL_MASK) == 0 && address <= UINT32_MAX &&
	    erx_vc_mbox_write_channel_set(word, ERX_VC_MBOX_WRITE_CHANNEL_PROPERTY, &word) &&
	    erx_vc_mbox_write_data_set(word, (uint32_t)(address >> 4), message));
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
	return (next(ERX_VC_MAILBOX_READ_STATUS, 0));
}

erx_vc_mailbox_step_t
erx_vc_mailbox_status(erx_vc_mailbox_t *mailbox, uint32_t status, uint64_t now)
{
	if (mailbox->state != ERX_VC_MAILBOX_POSTING && mailbox->state != ERX_VC_MAILBOX_POSTED)
		return (done(ERX_EINVAL));
	if (now >= mailbox->deadline) {
		/* The buffer is left to the firmware for the boot: a late answer would name it. */
		*mailbox = (erx_vc_mailbox_t){ .state = ERX_VC_MAILBOX_LOST };
		return (done(ERX_ETIMEDOUT));
	}
	if (mailbox->state == ERX_VC_MAILBOX_POSTING) {
		if (erx_vc_mbox_status_full_get(status) != 0)
			return (next(ERX_VC_MAILBOX_READ_STATUS, 0));
		mailbox->state = ERX_VC_MAILBOX_POSTED;
		return (next(ERX_VC_MAILBOX_WRITE, mailbox->message));
	}
	if (erx_vc_mbox_status_empty_get(status) != 0)
		return (next(ERX_VC_MAILBOX_READ_STATUS, 0));
	return (next(ERX_VC_MAILBOX_READ, 0));
}

erx_vc_mailbox_step_t
erx_vc_mailbox_read(erx_vc_mailbox_t *mailbox, uint32_t word)
{
	if (mailbox->state != ERX_VC_MAILBOX_POSTED)
		return (done(ERX_EINVAL));
	if (word != mailbox->message)
		return (next(ERX_VC_MAILBOX_READ_STATUS, 0));
	mailbox->state = ERX_VC_MAILBOX_ANSWERED;
	return (next(ERX_VC_MAILBOX_CHECK, 0));
}

void
erx_vc_mailbox_finish(erx_vc_mailbox_t *mailbox)
{
	if (mailbox->state == ERX_VC_MAILBOX_ANSWERED)
		*mailbox = (erx_vc_mailbox_t){ .state = ERX_VC_MAILBOX_IDLE };
}
