/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_CHANNEL_H
#define LIBERX_PROGRAM_CHANNEL_H

/*
 * The channel's send: the only writer of a program's outbound lane
 * (docs/design-programs.md, "The channel" and "Pending operations"), which
 * a build check holds to channel.c.  Any worker may send; one lock orders
 * the senders and is never held across a wait.  A frame is written whole
 * under the lock, and a sender that finds too little room for the whole
 * frame lets go of the lock and waits, in an open wait, until the event
 * executor announces room; so frames of two senders never interleave, and
 * no sender keeps another from the lane while it waits.
 *
 * The executor announces room with erx_prog_channel_room whenever it takes
 * the channel's label, which the session rings when its read crosses the
 * room a sender published that it needs.  The executor never sends: a send
 * may wait for room, which only the executor can announce.
 *
 * The channel also keeps the reply slots (inbound.h), under the same lock.
 * A worker's request takes a free slot, waiting for one in an open wait
 * when all are held, sends {erx_prog, Version, Slot, Request} and waits for
 * the reply in a closed wait, the request in flight being its obligation; the executor reads every frame after the
 * startup message through erx_prog_channel_frame, which puts a reply in
 * its slot and wakes its requester, so a reply reaches only the request on
 * its slot.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <erx/prog_profile.h>

#include "erx/lane.h"

/*
 * Readies the send over the program's two sides of its channel, own_side
 * read-write and peer_side read-only, and the session's doorbell, before
 * any thread sends.  False, and the send unusable, when the sides do not
 * make a lane of the ABI's size.
 */
bool	erx_prog_channel_open(void *own_side, const void *peer_side,
	    uint64_t doorbell);
/*
 * Writes the frame made of iov[0, iovcnt) whole into the outbound lane,
 * as one frame record, waiting for room for all of it when there is too
 * little, and rings the session's doorbell when the session waits for it.
 * ERX_OK when the frame is written; ERX_ERANGE, writing nothing, for a
 * frame whose record is larger than the ring or pieces the lane refuses
 * (erx_lane_put); ERX_EDEAD, writing nothing, once the session has broken
 * the lane, which no later send writes again.
 */
int	erx_prog_channel_send(const erx_lane_iov_t *iov, size_t iovcnt);
/*
 * The executor took the channel's label: room may have returned, so every
 * sender waiting for it looks again.
 */
void	erx_prog_channel_room(void);
/*
 * Makes a request of case request (ERX_PROG_REQUEST_...), whose value
 * value[0, len) is one term as erx_etf_writer writes it, its version byte
 * first: takes a free worker slot, waiting for one while all are held,
 * sends the request on it through erx_prog_channel_send and waits for the
 * reply, which it copies into *reply.  ERX_OK with *reply; the send's
 * ERX_ERANGE or ERX_EDEAD, with no reply.  The slot is free again either
 * way.  A reply holds no view into its frame: replies with texts or lists
 * need the frame kept with the slot.  The executor never makes a request.
 */
int	erx_prog_channel_request(uint16_t request, const uint8_t *value,
	    size_t len, erx_prog_reply_t *reply);
/*
 * The executor's read of a whole frame after the startup message,
 * frame[0, len), with scratch_len bytes of scratch (erx_prog_inbound_read):
 * a reply goes into its slot, whose requester it wakes, and a report into
 * *got for the executor to apply.  False when the profile refuses the
 * frame, a reply on a slot that awaits none among them.
 */
bool	erx_prog_channel_frame(const uint8_t *frame, size_t len, void *scratch,
	    size_t scratch_len, erx_prog_to_program_t *got);

#endif /* !LIBERX_PROGRAM_CHANNEL_H */
