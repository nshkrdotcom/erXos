/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of the event executor's inbound decisions
 * (liberx/program/inbound.h, test/host/prog_inbound_test.rb).  Each line of
 * the requests file is one request, each answered by one line:
 *   open STARTED KIND ZERO LEN	-> open start | frame | refuse
 *   frame HEX			-> refused, or
 *				   report WHICH PIPE END CAP... (the
 *				   capabilities erx_prog_report_caps names), or
 *				   reply SLOT kill ok | error ERRNUM (every
 *				   slot awaits a kill: a reply to another
 *				   request fails the driver)
 *   take kill			-> take SLOT (ERX_PROFILE_SLOTS for none), a
 *				   slot awaiting ERX_PROG_REQUEST_KILL's reply
 *   release SLOT			-> release
 *   state SLOT			-> state free | awaiting | answered
 * A frame is read with all the scratch erx_prog_scratch_bytes promises,
 * against the reply slots the requests before it left.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/program/inbound.h"

#define LINE_MAX_BYTES	4096

static erx_prog_slots_t slots;

static const char *const decisions[] = {
	[ERX_PROG_INBOUND_START] = "start",
	[ERX_PROG_INBOUND_FRAME] = "frame",
	[ERX_PROG_INBOUND_REFUSE] = "refuse",
};

/* hex's bytes into out; SIZE_MAX on a malformed line. */
static size_t
unhex(const char *hex, uint8_t *out, size_t room)
{
	size_t n = 0;
	unsigned byte;

	while (hex[0] != '\n' && hex[0] != '\0') {
		if (n == room || sscanf(hex, "%2x", &byte) != 1)
			return (SIZE_MAX);
		out[n++] = (uint8_t)byte;
		hex += 2;
	}
	return (n);
}

/* The report's pipe and end, which every report but pipe_server_lost names. */
static void
names(const erx_prog_report_t *r, uint32_t *pipe, uint32_t *end)
{
	*pipe = *end = 0;
	switch (r->which) {
	case ERX_PROG_REPORT_PIPE_WRITER:
		*pipe = r->u.pipe_writer.pipe_id;
		*end = r->u.pipe_writer.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_WRITER_GONE:
		*pipe = r->u.pipe_writer_gone.pipe_id;
		*end = r->u.pipe_writer_gone.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_READER:
		*pipe = r->u.pipe_reader.pipe_id;
		*end = r->u.pipe_reader.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_READER_GONE:
		*pipe = r->u.pipe_reader_gone.pipe_id;
		*end = r->u.pipe_reader_gone.end_id;
		break;
	case ERX_PROG_REPORT_PIPE_LOST:
		*pipe = r->u.pipe_lost.pipe_id;
		*end = r->u.pipe_lost.end_id;
		break;
	default:
		break;
	}
}

static void
frame_read(const uint8_t *frame, size_t len)
{
	erx_cap_t caps[ERX_PROG_REPORT_CAPS];
	const size_t scratch_len = erx_prog_scratch_bytes(len);
	void *scratch = malloc(scratch_len == 0 ? 1 : scratch_len);
	erx_prog_to_program_t got;
	const erx_prog_report_t *r = &got.u.report;
	uint32_t pipe, end;
	size_t n;

	if (scratch == NULL || !erx_prog_inbound_read(&slots, frame, len, scratch, scratch_len, &got)) {
		printf("refused\n");
		free(scratch);
		return;
	}
	if (got.frame == ERX_PROG_FRAME_REPLY) {
		const erx_prog_kill_reply_t *kill = &got.u.reply.u.kill;

		if (got.u.reply.request != ERX_PROG_REQUEST_KILL)
			exit(2);
		if (kill->which == ERX_PROG_KILL_REPLY_ERROR)
			printf("reply %u kill error %" PRId32 "\n", got.slot, kill->u.error.errnum);
		else
			printf("reply %u kill ok\n", got.slot);
		free(scratch);
		return;
	}
	names(r, &pipe, &end);
	printf("report %u %" PRIu32 " %" PRIu32, r->which, pipe, end);
	n = erx_prog_report_caps(r, caps);
	for (size_t at = 0; at < n; at++)
		printf(" %" PRIu64, caps[at].raw);
	printf("\n");
	free(scratch);
}

int
main(int argc, char **argv)
{
	static char line[LINE_MAX_BYTES];
	static uint8_t frame[LINE_MAX_BYTES / 2];
	unsigned started, number;
	uint32_t kind, len;
	uint64_t zero;
	FILE *requests;
	size_t n;

	if (argc != 2 || (requests = fopen(argv[1], "r")) == NULL)
		return (2);
	erx_prog_slots_init(&slots);
	while (fgets(line, sizeof(line), requests) != NULL) {
		if (sscanf(line, "open %u %" SCNu32 " %" SCNu64 " %" SCNu32,
		    &started, &kind, &zero, &len) == 4) {
			printf("open %s\n", decisions[erx_prog_inbound_open(started != 0, kind, zero, len)]);
			continue;
		}
		if (strcmp(line, "take kill\n") == 0) {
			printf("take %u\n", erx_prog_slot_take(&slots, ERX_PROG_REQUEST_KILL));
			continue;
		}
		if (sscanf(line, "release %u", &number) == 1 && number < ERX_PROFILE_SLOTS) {
			erx_prog_slot_release(&slots, number);
			printf("release\n");
			continue;
		}
		if (sscanf(line, "state %u", &number) == 1 && number < ERX_PROFILE_SLOTS) {
			printf("state %s\n", (slots.held & (1u << number)) == 0 ? "free" :
			    erx_prog_slot_answered(&slots, number) ? "answered" : "awaiting");
			continue;
		}
		if (strncmp(line, "frame ", 6) != 0 ||
		    (n = unhex(line + 6, frame, sizeof(frame))) == SIZE_MAX)
			return (2);
		frame_read(frame, n);
	}
	fclose(requests);
	return (0);
}
