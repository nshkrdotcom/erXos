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
 * firmware a small grid describes (words left in mailbox 0 before the post, each naming
 * this very buffer; polls before the answer; other messages ahead of it; whether it answers
 * this buffer, another or never; the clock's step per poll), following the steps as a
 * caller does. Around each step it checks that a second caller's begin is refused
 * ERX_EBUSY without changing anything; it checks that the one message posted is the
 * buffer's, posted once and only after mailbox 0 is drained, so no word left from before
 * is taken for the answer, and that the request ends ERX_OK exactly when the answer is
 * read before the deadline. After each request, a further begin must meet ERX_ETIMEDOUT at
 * once if it timed out and start afresh if not. It prints the counts of runs, answers and
 * timeouts; any broken check aborts.
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
static const char *const OPS[] = { "done", "fill", "read_status", "write", "read", "check" };

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

/* The buffer of NOTIFY_XHCI_RESET for the VL805 as the firmware answers it: performed. */
static erx_vc_answer_t
answer_notification(erx_vc_mailbox_t *mailbox)
{
	const uint32_t argument = UINT32_C(0x00100000);
	uint32_t words[ERX_VC_BUFFER_WORDS] = { 0 };
	uint8_t out[ERX_VC_WINDOW_MAX];

	(void)erx_vc_request(&erx_vc_notify_xhci_reset, &argument, words);
	words[1] = ERX_VC_CODE_SUCCESS;
	words[ERX_VC_VALUE_WORD - 1] = UINT32_C(0x80000000);
	return (erx_vc_mailbox_answer(mailbox, &erx_vc_notify_xhci_reset, words, out));
}

/* One event of the table on mailbox, by name. */
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
		step = erx_vc_mailbox_read(mailbox, MESSAGE, before);
	else if (strcmp(event, "read_other") == 0)
		step = erx_vc_mailbox_read(mailbox, MESSAGE + 0x1000, before);
	else if (strcmp(event, "read_channel") == 0)
		step = erx_vc_mailbox_read(mailbox, MESSAGE + 1, before);
	else if (strcmp(event, "read_late") == 0)
		step = erx_vc_mailbox_read(mailbox, MESSAGE, late);
	else if (strcmp(event, "answer") == 0) {
		printf("answer %" PRId32 " ", answer_notification(mailbox).status);
		return;
	} else
		abort();
	printf("%s %08" PRIx32 " %" PRId32 " ", OPS[step.op], step.message, step.status);
}

/* A firmware of the grid: the mailbox's side of one request. */
typedef enum { ANSWER_NONE, ANSWER_THIS, ANSWER_OTHER } answer_t;
typedef struct firmware {
	unsigned	stale;		/* words in mailbox 0 before the post, each this buffer's */
	unsigned	delay;		/* status reads after the post that show it empty */
	unsigned	noise;		/* other messages ahead of the answer */
	answer_t	answer;
	uint64_t	step_ns;	/* the clock's advance per poll */
} firmware_t;

/* What mailbox 0 holds over one request, and what has been read from it. */
typedef struct model {
	const firmware_t *fw;
	bool		posted;
	unsigned	stale_left, delay_left, delivered;
} model_t;

/* The poll whose read is the answer, counted from 0: the drain, the post's, the wait, the noise. */
static unsigned
answer_poll(const firmware_t *fw)
{
	return (fw->stale + 1 + fw->delay + fw->noise);
}

static bool
in_time(const firmware_t *fw, unsigned poll)
{
	return (poll * fw->step_ns < ERX_VC_DEADLINE_NS);
}

static unsigned
waiting(const model_t *model)
{
	if (!model->posted)
		return (model->stale_left);
	if (model->delay_left > 0)
		return (0);
	return (model->fw->noise + (model->fw->answer != ANSWER_NONE) - model->delivered);
}

/* STATUS as the model shows it; each read of it during the wait uses one poll of the wait. */
static uint32_t
model_status(model_t *model)
{
	if (model->posted && model->delay_left > 0) {
		model->delay_left--;
		return (STATUS_EMPTY);
	}
	return (waiting(model) > 0 ? 0 : STATUS_EMPTY);
}

/* READ as the model gives it: a stale word, then the noise, then the answer. */
static uint32_t
model_read(model_t *model)
{
	check(waiting(model) > 0);
	if (!model->posted) {
		model->stale_left--;
		return (MESSAGE);
	}
	if (model->delivered++ < model->fw->noise)
		return (UINT32_C(0x2001));
	return (model->fw->answer == ANSWER_THIS ? MESSAGE : MESSAGE + 0x10);
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

/* One request against fw, as a caller runs it: one clock reading per poll; returns its status. */
static erx_status_t
run(erx_vc_mailbox_t *mailbox, const firmware_t *fw)
{
	model_t model = { .fw = fw, .stale_left = fw->stale, .delay_left = fw->delay };
	unsigned polls = 0;
	uint64_t now = START;
	erx_vc_mailbox_step_t step = erx_vc_mailbox_begin(mailbox, BUFFER, now);

	check(step.op == ERX_VC_MAILBOX_FILL);
	for (;;) {
		if (step.op != ERX_VC_MAILBOX_DONE)
			check_refused(mailbox, now);
		switch (step.op) {
		case ERX_VC_MAILBOX_DONE:
			check(step.status == ERX_ETIMEDOUT && mailbox->state == ERX_VC_MAILBOX_LOST);
			check(fw->answer != ANSWER_THIS || !in_time(fw, answer_poll(fw)));
			check(model.posted == in_time(fw, fw->stale));
			return (step.status);
		case ERX_VC_MAILBOX_CHECK:
			check(fw->answer == ANSWER_THIS && polls == answer_poll(fw) + 1 && model.posted);
			check(model.stale_left == 0 && in_time(fw, answer_poll(fw)));
			check(answer_notification(mailbox).status == ERX_OK);
			check(mailbox->state == ERX_VC_MAILBOX_IDLE);
			return (ERX_OK);
		case ERX_VC_MAILBOX_FILL:
			step = (erx_vc_mailbox_step_t){ .op = ERX_VC_MAILBOX_READ_STATUS };
			break;
		case ERX_VC_MAILBOX_WRITE:
			check(step.message == MESSAGE && !model.posted && model.stale_left == 0);
			model.posted = true;
			step = (erx_vc_mailbox_step_t){ .op = ERX_VC_MAILBOX_READ_STATUS };
			break;
		case ERX_VC_MAILBOX_READ_STATUS:
			check(polls <= answer_poll(fw) + ERX_VC_DEADLINE_NS / fw->step_ns + 1);
			now = START + polls++ * fw->step_ns;
			step = erx_vc_mailbox_status(mailbox, model_status(&model), now);
			break;
		case ERX_VC_MAILBOX_READ:
			step = erx_vc_mailbox_read(mailbox, model_read(&model), now);
			break;
		}
	}
}

static void
model_mailbox(void)
{
	static const uint64_t steps[] = { 1000000, 100000000, 250000000, 333333334, 1000000000 };
	unsigned runs = 0, answered = 0, timed_out = 0;

	for (unsigned stale = 0; stale < 3; stale++)
		for (unsigned delay = 0; delay < 4; delay++)
			for (unsigned noise = 0; noise < 4; noise++)
				for (unsigned answer = ANSWER_NONE; answer <= ANSWER_OTHER; answer++)
					for (size_t at = 0; at < sizeof(steps) / sizeof(steps[0]); at++) {
						const firmware_t fw = { stale, delay, noise, (answer_t)answer, steps[at] };
						erx_vc_mailbox_t mailbox = { 0 };
						const erx_status_t status = run(&mailbox, &fw);
						const erx_vc_mailbox_step_t again = erx_vc_mailbox_begin(&mailbox, BUFFER, START);

						runs++;
						if (status == ERX_OK) {
							answered++;
							check(again.op == ERX_VC_MAILBOX_FILL);
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
