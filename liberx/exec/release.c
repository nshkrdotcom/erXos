/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The release of a loader's span and its exec record (release.h): a pure
 * check of the span the record gives against the loader the executable
 * was linked with, and the effect that copies the span once out of the
 * record and releases it, then the record's page, through the space's
 * release call. The space releases whole mappings only, so a span that
 * reaches into part of a neighbour's mapping is refused there, not cut
 * short.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "liberx/backend/api.h"
#include "liberx/exec/release.h"

/*
 * Whether a and b share a byte. Neither end is computed, so a range that
 * ends at 2^64, as a record's page may, compares as any other.
 */
static bool
meets(erx_exec_range_t a, erx_exec_range_t b)
{
	if (b.address <= a.address)
		return (a.address - b.address < b.size);
	return (b.address - a.address < a.size);
}

bool
erx_exec_record_placed(uint64_t record)
{
	return (record != 0 && record % ERX_PAGE_SIZE == 0);
}

/*
 * The loader's span is the build's, from the loader's link, so a recorded
 * span equal to it is page-aligned, not empty and ends within 64 bits; a
 * loader of size 0 is no loader at all, and no record matches it.
 */
erx_exec_release_verdict_t
erx_exec_release_check(uint64_t record, erx_exec_range_t recorded, erx_exec_range_t own,
    erx_exec_range_t loader)
{
	const erx_exec_range_t page = { .address = record, .size = ERX_PAGE_SIZE };

	if (!erx_exec_record_placed(record))
		return (ERX_EXEC_RELEASE_RECORD);
	if (loader.size == 0 || recorded.address != loader.address || recorded.size != loader.size)
		return (ERX_EXEC_RELEASE_LOADER);
	if (meets(loader, own))
		return (ERX_EXEC_RELEASE_LOADER_IMAGE);
	if (meets(page, own))
		return (ERX_EXEC_RELEASE_RECORD_IMAGE);
	if (meets(page, loader))
		return (ERX_EXEC_RELEASE_RECORD_LOADER);
	return (ERX_EXEC_RELEASE_GO);
}

bool
erx_exec_release(uint64_t record, erx_exec_range_t own, erx_exec_range_t loader)
{
	erx_exec_record_t fields = { 0 };
	erx_exec_range_t recorded;

	/*
	 * Each field the release uses is read once, here, and only from a
	 * placed record when a loader is linked, so a fixed-link task never
	 * reads what register 7 names; the decode refuses only a null or
	 * short buffer, and a placed record is neither.
	 */
	if (loader.size != 0 && erx_exec_record_placed(record))
		(void)erx_exec_record_decode((const uint8_t *)(uintptr_t)record, ERX_EXEC_RECORD_SIZE, &fields);
	recorded = (erx_exec_range_t){ .address = fields.loader_base, .size = fields.loader_size };
	return (erx_exec_release_check(record, recorded, own, loader) == ERX_EXEC_RELEASE_GO &&
	    erx_vm_release(ERX_CAP_SELF, loader.address, loader.size) == ERX_OK &&
	    erx_vm_release(ERX_CAP_SELF, record, ERX_PAGE_SIZE) == ERX_OK);
}
