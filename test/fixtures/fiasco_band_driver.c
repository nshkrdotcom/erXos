/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The Fiasco backend's bands on the host (test/host/fiasco_band_test.rb): each
 * band's base and ceiling, the bands a new task takes and the decoder's word count
 * of domain_space_create. Each check prints one line, which the test compares whole.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/band.h"
#include "liberx/backend/fiasco/service_wire.h"

/* A domain row of an interactive domain, task 7, whose sub-spaces run in the app band. */
static const erx_fiasco_task_band_t session_row = { .domain = 7, .band = ERX_BAND_INTERACTIVE,
    .space_band = ERX_BAND_APP, .slice_us = 1000, .cpuset = 0x3 };

static void
print_bands(const char *name, int status, const erx_fiasco_task_band_t *bands)
{
	printf("%s %d domain=%u band=%u space_band=%u slice_us=%u cpuset=%#llx\n", name, status, bands->domain,
	    bands->band, bands->space_band, bands->slice_us, (unsigned long long)bands->cpuset);
}

/* The domain row a domain create asks for; a refused one leaves the row zeroed. */
static void
domain_create(const char *name, uint32_t band, uint32_t space_band, uint32_t slice_us)
{
	const erx_fiasco_domain_space_create_request_t request = { .band = band, .space_band = space_band,
	    .cpuset = 0xc, .slice_us = slice_us };
	erx_fiasco_task_band_t bands = { 0 };

	print_bands(name, erx_fiasco_band_domain(&request, &bands), &bands);
}

static bool
live(uint32_t task)
{
	return (task == 1);
}

static void
wire(const char *name, uint32_t words)
{
	const uint64_t mr[ERX_FIASCO_WIRE_WORDS_MAX + 1] = { 0 };
	const erx_fiasco_wire_input_t input = { .label = UINT64_C(1) << ERX_FIASCO_WIRE_LABEL_SHIFT,
	    .tag_label = ERX_FIASCO_CALL_DOMAIN_SPACE_CREATE, .words = words, .task_live = live, .mr = mr };
	const erx_fiasco_wire_decoded_t decoded = erx_fiasco_wire_decode(&input);

	printf("wire %s kind=%d status=%d\n", name, (int)decoded.kind, (int)decoded.status);
}

int
main(void)
{
	const erx_band_t bands[] = { ERX_FIASCO_BAND_WATCHDOG, ERX_FIASCO_BAND_ROOT, ERX_BAND_DRIVER,
	    ERX_BAND_INTERACTIVE, ERX_BAND_APP, ERX_FIASCO_BAND_NONE, ERX_FIASCO_BAND_WATCHDOG + 1 };
	const erx_fiasco_task_band_t inherited = erx_fiasco_band_inherit(&session_row, 7);

	/* Each band's levels, base..ceiling. */
	printf("levels");
	for (size_t at = 0; at < sizeof(bands) / sizeof(bands[0]); at++)
		printf(" %u..%u", erx_fiasco_band_levels(bands[at]).base, erx_fiasco_band_levels(bands[at]).ceiling);
	printf("\n");

	domain_create("domain driver", ERX_BAND_DRIVER, ERX_BAND_DRIVER, 1000);
	domain_create("domain session", ERX_BAND_INTERACTIVE, ERX_BAND_APP, ERX_SLICE_MIN_US);
	domain_create("domain app", ERX_BAND_APP, ERX_BAND_APP, ERX_SLICE_MAX_US);
	domain_create("domain band_zero", 0, ERX_BAND_APP, 1000);
	domain_create("domain band_past", ERX_BAND_APP + 1, ERX_BAND_APP, 1000);
	domain_create("domain space_band_zero", ERX_BAND_DRIVER, 0, 1000);
	domain_create("domain space_band_past", ERX_BAND_DRIVER, UINT32_MAX, 1000);
	domain_create("domain slice_short", ERX_BAND_DRIVER, ERX_BAND_DRIVER, ERX_SLICE_MIN_US - 1);
	domain_create("domain slice_long", ERX_BAND_DRIVER, ERX_BAND_DRIVER, ERX_SLICE_MAX_US + 1);

	/* A program of the session, which a task of the session's domain makes. */
	print_bands("space of_session", 0, &inherited);

	wire("exact", sizeof(erx_fiasco_domain_space_create_request_t) / sizeof(uint64_t));
	wire("short", sizeof(erx_fiasco_space_create_request_t) / sizeof(uint64_t));
	wire("long", ERX_FIASCO_WIRE_WORDS_MAX + 1);
	return (0);
}
