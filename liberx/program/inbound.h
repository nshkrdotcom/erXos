/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_INBOUND_H
#define LIBERX_PROGRAM_INBOUND_H

/*
 * The event executor's decisions on the inbound lane of a program's channel
 * (docs/design-programs.md, "The program protocol" and "The event
 * executor"), as pure functions the host tests exhaustively.  The handler
 * writes one startup message and then reports and replies, each a frame
 * record: the executor asks erx_prog_inbound_open what a record's header
 * admits, copies the record whole, and then plans the start-up (startup.h)
 * or reads the frame with erx_prog_inbound_read.  Anything else, a record
 * of another kind, a header with a nonzero zero word, an empty record, a
 * startup message past ERX_PROG_FRAME_MAX, a later frame past
 * ERX_PROG_REPORT_MAX or a frame the profile refuses, ends the program
 * with ERX_PROG_STATUS_REFUSED.
 *
 * The reply slots are a state machine here too, which the channel
 * (channel.h) keeps under its lock.  A slot is free; then awaits the reply
 * to the request a requester made on it, from the moment it took the slot
 * until a reply on it is read; then holds that reply, answered, until the
 * requester lets go of it.  busy is the profile check's: the request case
 * an awaiting slot holds, and ERX_PROFILE_NONE for a free or an answered
 * one, so the check refuses a reply on a slot that awaits none, a second
 * reply among them, and a reply that is not the reply its slot's request
 * takes.  Workers take slots 0 to ERX_PROG_EXECUTOR_SLOT - 1; the last is
 * the event executor's own.
 *
 * Like startup.c, this reads only its arguments: no kernel call, no page.
 * Both bounds are abi/protocols/prog.txt's limits, and the capabilities a
 * report installs, which the executor closes for an end the program no
 * longer holds, are named by the profile's generated erx_prog_report_caps.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <erx/abi.h>
#include <erx/prog_profile.h>

/* What the executor does with a record whose header the inbound lane opened. */
typedef enum erx_prog_inbound {
	ERX_PROG_INBOUND_START,		/* the startup message: copy it, then plan */
	ERX_PROG_INBOUND_FRAME,		/* a report or a reply: copy it, then read it */
	ERX_PROG_INBOUND_REFUSE		/* stop with ERX_PROG_STATUS_REFUSED */
} erx_prog_inbound_t;

/* The event executor's own reply slot; the workers' are below it. */
#define ERX_PROG_EXECUTOR_SLOT	(ERX_PROFILE_SLOTS - 1)

/*
 * The reply slots: busy is the check's, held has a bit for each slot not
 * free, and replies[s] is slot s's reply once it is answered.
 */
typedef struct erx_prog_slots {
	erx_prog_reply_t replies[ERX_PROFILE_SLOTS];
	uint16_t	busy[ERX_PROFILE_SLOTS];
	uint16_t	held;
} erx_prog_slots_t;

_Static_assert(ERX_PROFILE_SLOTS <= 16, "a bit of held for each slot");

/*
 * The decision on a record's header: kind, zero word and body length.
 * started says the startup message's record was opened before: the first
 * record is the startup message, and every later one a report or a reply.
 */
erx_prog_inbound_t erx_prog_inbound_open(bool started, uint32_t kind,
	    uint64_t zero, uint32_t len);

/* Every slot free. */
void	erx_prog_slots_init(erx_prog_slots_t *slots);
/*
 * Takes the lowest free worker slot to await the reply to request, a case
 * of the request union (ERX_PROG_REQUEST_...), and returns it; returns
 * ERX_PROFILE_SLOTS, changing nothing, when every worker slot is held.
 */
unsigned erx_prog_slot_take(erx_prog_slots_t *slots, uint16_t request);
/* Whether slot slot is held and holds its reply, in replies[slot]. */
bool	erx_prog_slot_answered(const erx_prog_slots_t *slots, unsigned slot);
/* Lets go of the held slot slot, answered or still awaiting, which is free again. */
void	erx_prog_slot_release(erx_prog_slots_t *slots, unsigned slot);

/*
 * Reads a frame after the startup message, frame[0, len), copied whole,
 * with scratch_len bytes of scratch, into *got: a report, or a reply on a
 * slot awaiting one, which the read stores in the slot's replies entry and
 * moves to answered.  False refuses the
 * frame and changes no slot.  With erx_prog_scratch_bytes(len) bytes of
 * scratch the profile's check never refuses for scratch.
 */
bool	erx_prog_inbound_read(erx_prog_slots_t *slots, const uint8_t *frame,
	    size_t len, void *scratch, size_t scratch_len,
	    erx_prog_to_program_t *got);

#endif /* !LIBERX_PROGRAM_INBOUND_H */
