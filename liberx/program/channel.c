/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The channel's send (channel.h).  The lane's writer state is guarded by
 * one mutex, which a sender holds from its first look at the room to the
 * record's last byte and lets go of before every wait.  The items it puts
 * are marked whole, so a put writes all of a frame or none of it, and the
 * writer is never left inside a record that another sender would find.
 *
 * The wait for room is a wait on an object (wake.h): a sender reads its
 * wake word, puts itself on the channel's waiters and puts armed, which
 * publishes the room it needs, fences and looks once more, all under the
 * lock.  Once the session's read crosses that need it rings the doorbell,
 * and the executor takes the label and wakes the waiters under the same
 * lock, so it finds the sender on the list and bumps the word the sender
 * read, and the sender's sleep returns.  A woken sender takes the lock
 * and puts again, so a wake that brought too little room only sends it
 * back to wait.
 *
 * The lane has one need word, and each armed put overwrites it, so it
 * holds the need of the sender that published last.  While that sender
 * waits, its need's crossing wakes every waiter.  A sender that leaves
 * the lane, its frame written or the lane broken, may be the one whose
 * need is published, and the need of a sender still waiting then stands
 * nowhere; so a sender that leaves while others wait wakes them itself,
 * and each of them publishes its need again.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/etf.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"
#include "liberx/program/inbound.h"
#include "liberx/program/wake.h"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
/* Under lock, once erx_prog_channel_open has readied it. */
static erx_lane_writer_t outbound;
/* Set by erx_prog_channel_open before any thread sends. */
static uint64_t doorbell;
/* The senders waiting for room, under lock. */
static erx_prog_waitq_t room_waiters;
/* The reply slots and the workers waiting on them, under lock. */
static erx_prog_slots_t slots;
static erx_prog_waitq_t reply_waiters[ERX_PROFILE_SLOTS];	/* a slot's requester */
static erx_prog_waitq_t slot_waiters;				/* workers without a slot */

/* A request's envelope before its value, the version byte and {erx_prog, Version, Slot,: 17 bytes. */
#define ENVELOPE_MAX	32

bool
erx_prog_channel_open(void *own_side, const void *peer_side, uint64_t bell)
{
	doorbell = bell;
	erx_prog_slots_init(&slots);
	return (erx_lane_writer_init(&outbound, own_side, peer_side, ERX_PROGRAM_LANE));
}

/*
 * Puts the item under the lock until the lane takes it whole or refuses it,
 * letting go of the lock while it waits for room, and returns DONE, REFUSED
 * or MALFORMED, never SHORT. What the last put did is in *put.
 */
static erx_lane_put_status_t
whole_put(const erx_lane_item_t *item, erx_lane_put_t *put)
{
	erx_lane_put_status_t status;

	(void)pthread_mutex_lock(&lock);
	/* A lane with room takes the frame without publishing a need, which would cost a ring. */
	status = erx_lane_put(&outbound, item, put);
	while (status == ERX_LANE_PUT_SHORT) {
		const uint32_t seen = erx_prog_wake_seen();
		erx_prog_waiter_t me;

		erx_prog_waitq_join(&room_waiters, &me);
		status = erx_lane_put_armed(&outbound, item, put);
		if (status == ERX_LANE_PUT_SHORT) {
			(void)pthread_mutex_unlock(&lock);
			/* The open wait: the sender holds nothing of the channel's here. */
			erx_prog_wake_sleep(seen, ERX_WAIT_FOREVER);
			(void)pthread_mutex_lock(&lock);
		}
		erx_prog_waitq_leave(&room_waiters, &me);
	}
	/* This sender leaves: a need it published stands for none of those still waiting. */
	erx_prog_waitq_wake(&room_waiters);
	(void)pthread_mutex_unlock(&lock);
	return (status);
}

int
erx_prog_channel_send(const erx_lane_iov_t *iov, size_t iovcnt)
{
	const erx_lane_item_t item = { .iov = iov, .iovcnt = iovcnt, .kind = ERX_REC_FRAME, .whole = true };
	erx_lane_put_t put;

	switch (whole_put(&item, &put)) {
	case ERX_LANE_PUT_DONE:
		/* The session may wait for this frame; a failed ring is the session's to miss. */
		if (put.ring)
			(void)erx_irq_trigger(doorbell);
		return (ERX_OK);
	case ERX_LANE_PUT_REFUSED:
		return (ERX_ERANGE);
	case ERX_LANE_PUT_SHORT:	/* whole_put never returns it */
	case ERX_LANE_PUT_MALFORMED:
		break;
	}
	return (ERX_EDEAD);
}

void
erx_prog_channel_room(void)
{
	(void)pthread_mutex_lock(&lock);
	erx_prog_waitq_wake(&room_waiters);
	(void)pthread_mutex_unlock(&lock);
}

/*
 * Under the lock, until the calling worker holds a slot for request: takes
 * a free one, or joins those waiting for one and waits, as whole_put waits
 * for room.
 */
static unsigned
slot_take(uint16_t request)
{
	unsigned slot;

	while ((slot = erx_prog_slot_take(&slots, request)) == ERX_PROFILE_SLOTS) {
		const uint32_t seen = erx_prog_wake_seen();
		erx_prog_waiter_t me;

		erx_prog_waitq_join(&slot_waiters, &me);
		(void)pthread_mutex_unlock(&lock);
		erx_prog_wake_sleep(seen, ERX_WAIT_FOREVER);
		(void)pthread_mutex_lock(&lock);
		erx_prog_waitq_leave(&slot_waiters, &me);
	}
	return (slot);
}

/*
 * Under the lock, until the reply to the request on slot is there: a closed
 * wait, since the request in flight is the thread's obligation, and with no
 * deadline (docs/design-programs.md, "Open and closed waits").
 */
static void
reply_wait(unsigned slot)
{
	while (!erx_prog_slot_answered(&slots, slot)) {
		const uint32_t seen = erx_prog_wake_seen();
		erx_prog_waiter_t me;

		erx_prog_waitq_join(&reply_waiters[slot], &me);
		(void)pthread_mutex_unlock(&lock);
		erx_prog_wake_sleep(seen, ERX_WAIT_FOREVER);
		(void)pthread_mutex_lock(&lock);
		erx_prog_waitq_leave(&reply_waiters[slot], &me);
	}
}

int
erx_prog_channel_request(uint16_t request, const uint8_t *value, size_t len,
    erx_prog_reply_t *reply)
{
	const erx_profile_frame_t *const frame = &erx_prog_profile.frames[ERX_PROG_FRAME_REQUEST];
	uint8_t envelope[ENVELOPE_MAX];
	erx_lane_iov_t iov[2];
	erx_etf_writer_t writer;
	size_t envelope_len;
	unsigned slot;
	int status;

	(void)pthread_mutex_lock(&lock);
	slot = slot_take(request);
	(void)pthread_mutex_unlock(&lock);

	/* {Tag, Version, Slot, Value}: the value's own version byte gives way to the envelope's. */
	erx_etf_writer_init(&writer, envelope, sizeof(envelope));
	erx_etf_put_tuple(&writer, 4);
	erx_etf_put_atom(&writer, frame->tag, strlen(frame->tag));
	erx_etf_put_integer(&writer, (int64_t)erx_prog_profile.version);
	erx_etf_put_integer(&writer, slot);
	if (!erx_etf_writer_done(&writer, &envelope_len))
		envelope_len = 0;	/* not reached: ENVELOPE_MAX holds it */
	iov[0] = (erx_lane_iov_t){ .base = envelope, .len = envelope_len };
	iov[1] = (erx_lane_iov_t){ .base = value + 1, .len = len - 1 };
	status = erx_prog_channel_send(iov, 2);

	(void)pthread_mutex_lock(&lock);
	if (status == ERX_OK) {
		reply_wait(slot);
		*reply = slots.replies[slot];
	}
	erx_prog_slot_release(&slots, slot);
	erx_prog_waitq_wake(&slot_waiters);
	(void)pthread_mutex_unlock(&lock);
	return (status);
}

bool
erx_prog_channel_frame(const uint8_t *frame, size_t len, void *scratch,
    size_t scratch_len, erx_prog_to_program_t *got)
{
	bool read;

	(void)pthread_mutex_lock(&lock);
	read = erx_prog_inbound_read(&slots, frame, len, scratch, scratch_len, got);
	if (read && got->frame == ERX_PROG_FRAME_REPLY)
		erx_prog_waitq_wake(&reply_waiters[got->slot]);
	(void)pthread_mutex_unlock(&lock);
	return (read);
}
