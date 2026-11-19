/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's file verdicts (verdict.h), a pure core over a table and an archive view
 * that builds for the host. slice.c holds the root's one table.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/verdict.h"

/* An entry's verdict; a table of zeroes is unchecked throughout. */
typedef enum verdict {
	VERDICT_UNCHECKED = 0,
	VERDICT_GOOD,
	VERDICT_REFUSED
} verdict_t;

static verdict_t	verdict_of(const erx_fiasco_verdicts_t *, uint32_t);

int
erx_fiasco_verdict_check(erx_fiasco_verdicts_t *verdicts, const erx_pack_view_t *view, uint32_t index,
    erx_blake3_ctx_t *hasher)
{
	erx_pack_error_t error;
	verdict_t verdict;

	if (index >= view->header.nentries || index >= ERX_PACK_ENTRIES_MAX)
		return (ERX_ERANGE);
	verdict = verdict_of(verdicts, index);
	if (verdict == VERDICT_UNCHECKED) {
		verdict = erx_pack_file_check(view, index, hasher, &error) ? VERDICT_GOOD : VERDICT_REFUSED;
		atomic_store_explicit(&verdicts->entry[index], (uint8_t)verdict, memory_order_release);
	}
	return (verdict == VERDICT_GOOD ? ERX_OK : ERX_ECORRUPT);
}

bool
erx_fiasco_verdict_good(const erx_fiasco_verdicts_t *verdicts, uint32_t index)
{
	return (index < ERX_PACK_ENTRIES_MAX && verdict_of(verdicts, index) == VERDICT_GOOD);
}

/* Entry index's verdict, which is below ERX_PACK_ENTRIES_MAX. */
static verdict_t
verdict_of(const erx_fiasco_verdicts_t *verdicts, uint32_t index)
{
	return ((verdict_t)atomic_load_explicit(&verdicts->entry[index], memory_order_acquire));
}
