/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/vc_mailbox.c for test/host/vc_mailbox_test.rb in two parts.
 *
 * The table: every event from every state. Each line of standard input names a state and
 * an event; the driver sets the state, applies the event and prints the step and the state
 * after it, which the test compares with its own model of the design.
 *
 * The model mailbox: with no input lines left, the driver runs one request against every
 * firmware a small grid describes (polls the mailbox stays full, polls before the answer,
 * other messages ahead of it, whether it answers this buffer, another or never, and the
 * clock's step per poll), following the steps as a caller does. Around each step it checks
 * that a second caller's begin is refused ERX_EBUSY without changing anything, that the
 * one message posted is the buffer's, that nothing is posted twice or after a timeout, and
 * that the request ends ERX_OK exactly when the answer is read before the deadline. After
 * each request, a further begin must meet ERX_ETIMEDOUT at once if it timed out and start
 * afresh if not. It prints the counts of runs, answers and timeouts; any broken check
 * aborts.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/vc_mailbox.h"

#define BUFFER		UINT64_C(0x1000)
#define MESSAGE		UINT32_C(0x1008)
#define START		UINT64_C(5000)
#define STATUS_EMPTY	UINT32_C(0x40000000)
#define STATUS_FULL	UINT32_C(0x80000000)

static void
check(bool condition)
{
	if (!condition)
		abort();
}

static const char *const STATES[] = { "idle", "posting", "posted", "answered", "lost" };
static const char *const OPS[] = { "done", "read_status", "write", "read", "check" };

static erx_vc_mailbox_t
state_named(const char *name)
{
	for (size_t at = 0; at < sizeof(STATES) / sizeof(STATES[0]); at++)
		if (strcmp(name, STATES[at]) == 0) {
			const bool outstanding = at != ERX_VC_MAILBOX_IDLE && at != ERX_VC_MAILBOX_LOST;

			return ((erx_vc_mailbox_t){
				.state = (erx_vc_mailbox_state_t)at,
				.message = outstanding ? MESSAGE : 0,
				.deadline = outstanding ? START + ERX_VC_DEADLINE_NS : 0,
			});
		}
	abort();
}

/* One event of the table on mailbox, by name; finish has no step and prints "-". */
static void
apply(erx_vc_mailbox_t *mailbox, const char *event)
{
	const uint64_t before = START + ERX_VC_DEADLINE_NS - 1, late = START + ERX_VC_DEADLINE_NS;
	erx_vc_mailbox_step_t step;

	if (strcmp(event, "begin") == 0)
		step = erx_vc_mailbox_begin(mailbox, BUFFER, START);
	else if (strcmp(event, "begin_misaligned") == 0)
		step = erx_vc_mailbox_begin(mailbox, BUFFER + 4, START);
	else if (strcmp(event, "begin_high") == 0)
		step = erx_vc_mailbox_begin(mailbox, UINT64_C(0x100000000), START);
	else if (strcmp(event, "begin_top") == 0)
		step = erx_vc_mailbox_begin(mailbox, UINT64_C(0xfffffff0), UINT64_MAX - 5);
	else if (strcmp(event, "status_room") == 0)
		step = erx_vc_mailbox_status(mailbox, 0, before);
	else if (strcmp(event, "status_full") == 0)
		step = erx_vc_mailbox_status(mailbox, STATUS_FULL, before);
	else if (strcmp(event, "status_empty") == 0)
		step = erx_vc_mailbox_status(mailbox, STATUS_EMPTY, before);
	else if (strcmp(event, "status_both") == 0)
		step = erx_vc_mailbox_status(mailbox, STATUS_FULL | STATUS_EMPTY, before);
	else if (strcmp(event, "status_late") == 0)
		step = erx_vc_mailbox_status(mailbox, STATUS_EMPTY, late);
	else if (strcmp(event, "read_match") == 0)
		step = erx_vc_mailbox_read(mailbox, MESSAGE);
	else if (strcmp(event, "read_other") == 0)
		step = erx_vc_mailbox_read(mailbox, MESSAGE + 0x1000);
	else if (strcmp(event, "read_channel") == 0)
		step = erx_vc_mailbox_read(mailbox, MESSAGE + 1);
	else if (strcmp(event, "finish") == 0) {
		erx_vc_mailbox_finish(mailbox);
		printf("- ");
		return;
	} else
		abort();
	printf("%s %08" PRIx32 " %" PRId32 " ", OPS[step.op], step.word, step.status);
}

/* A firmware of the grid: the mailbox's side of one request. */
typedef enum { ANSWER_NONE, ANSWER_THIS, ANSWER_OTHER } answer_t;
typedef struct firmware {
	unsigned	full_polls;	/* status reads that show FULL before room */
	unsigned	delay;		/* status reads after the post that show EMPTY */
	unsigned	noise;		/* other messages ahead of the answer */
	answer_t	answer;
	uint64_t	step_ns;	/* the clock's advance per status read */
} firmware_t;

/* The status read whose message is the answer, counted from 0: room, the wait, the noise. */
static unsigned
answer_poll(const firmware_t *fw)
{
	return (fw->full_polls + 1 + fw->delay + fw->noise);
}

/* A second caller's begin, between any two steps, changes nothing and is refused. */
static void
check_refused(erx_vc_mailbox_t *mailbox, uint64_t now)
{
	const erx_vc_mailbox_t before = *mailbox;
	const erx_vc_mailbox_step_t step = erx_vc_mailbox_begin(mailbox, BUFFER + 0x10, now);

	check(step.op == ERX_VC_MAILBOX_DONE && step.status == ERX_EBUSY);
	check(memcmp(&before, mailbox, sizeof(before)) == 0);
}

/* One request against fw, as a caller runs it; returns its status. */
static erx_status_t
run(erx_vc_mailbox_t *mailbox, const firmware_t *fw)
{
	uint64_t now = START;
	unsigned polls = 0, writes = 0, delivered = 0, delay = fw->delay, full = fw->full_polls;
	erx_vc_mailbox_step_t step = erx_vc_mailbox_begin(mailbox, BUFFER, now);

	check(step.op == ERX_VC_MAILBOX_READ_STATUS);
	for (;;) {
		uint32_t status;

		if (step.op != ERX_VC_MAILBOX_DONE)
			check_refused(mailbox, now);
		switch (step.op) {
		case ERX_VC_MAILBOX_DONE:
			check(step.status == ERX_ETIMEDOUT && mailbox->state == ERX_VC_MAILBOX_LOST);
			check(fw->answer != ANSWER_THIS || START + answer_poll(fw) * fw->step_ns >= START + ERX_VC_DEADLINE_NS);
			check(writes == (START + fw->full_polls * fw->step_ns < START + ERX_VC_DEADLINE_NS));
			return (step.status);
		case ERX_VC_MAILBOX_CHECK:
			check(fw->answer == ANSWER_THIS && polls == answer_poll(fw) + 1 && writes == 1);
			check(START + answer_poll(fw) * fw->step_ns < START + ERX_VC_DEADLINE_NS);
			erx_vc_mailbox_finish(mailbox);
			check(mailbox->state == ERX_VC_MAILBOX_IDLE);
			return (ERX_OK);
		case ERX_VC_MAILBOX_WRITE:
			check(step.word == MESSAGE && writes++ == 0);
			step = (erx_vc_mailbox_step_t){ .op = ERX_VC_MAILBOX_READ_STATUS };
			break;
		case ERX_VC_MAILBOX_READ_STATUS:
			check(polls <= answer_poll(fw) + ERX_VC_DEADLINE_NS / fw->step_ns + 1);
			if (writes == 0)
				status = full > 0 ? (full--, STATUS_FULL) : 0;
			else if (delay > 0)
				status = (delay--, STATUS_EMPTY);
			else
				status = delivered < fw->noise + (fw->answer != ANSWER_NONE) ? 0 : STATUS_EMPTY;
			step = erx_vc_mailbox_status(mailbox, status, now);
			polls++;
			now += fw->step_ns;
			break;
		case ERX_VC_MAILBOX_READ:
			/* Reading an empty mailbox is a step the routine must never ask for. */
			check(writes == 1 && delay == 0 && delivered < fw->noise + (fw->answer != ANSWER_NONE));
			step = erx_vc_mailbox_read(mailbox,
			    delivered++ < fw->noise ? UINT32_C(0x2001) :
			    fw->answer == ANSWER_THIS ? MESSAGE : MESSAGE + 0x10);
			break;
		}
	}
}

static void
model_mailbox(void)
{
	static const uint64_t steps[] = { 1000000, 100000000, 250000000, 333333334, 1000000000 };
	unsigned runs = 0, answered = 0, timed_out = 0;

	for (unsigned full = 0; full < 4; full++)
		for (unsigned delay = 0; delay < 4; delay++)
			for (unsigned noise = 0; noise < 4; noise++)
				for (unsigned answer = ANSWER_NONE; answer <= ANSWER_OTHER; answer++)
					for (size_t at = 0; at < sizeof(steps) / sizeof(steps[0]); at++) {
						const firmware_t fw = { full, delay, noise, (answer_t)answer, steps[at] };
						erx_vc_mailbox_t mailbox = { 0 };
						const erx_status_t status = run(&mailbox, &fw);
						const erx_vc_mailbox_step_t again = erx_vc_mailbox_begin(&mailbox, BUFFER, START);

						runs++;
						if (status == ERX_OK) {
							answered++;
							check(again.op == ERX_VC_MAILBOX_READ_STATUS);
						} else {
							timed_out++;
							check(again.op == ERX_VC_MAILBOX_DONE && again.status == ERX_ETIMEDOUT);
							check(mailbox.state == ERX_VC_MAILBOX_LOST);
						}
					}
	printf("model %u %u %u\n", runs, answered, timed_out);
}

int
main(void)
{
	char state[32], event[32];

	while (scanf("%31s %31s", state, event) == 2) {
		erx_vc_mailbox_t mailbox = state_named(state);

		apply(&mailbox, event);
		printf("%s %08" PRIx32 " %" PRIu64 "\n", STATES[mailbox.state], mailbox.message, mailbox.deadline);
	}
	model_mailbox();
	return (0);
}
