/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The release of a loader's span and its exec record (release.h): a pure
 * check of the span the record gives, and the effect that copies the span
 * once out of the record and releases it, then the record's page, through
 * the space's release call. The space releases whole mappings only, so a
 * span that reaches into part of a neighbour's mapping is refused there,
 * not cut short.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/exec/release.h"

static bool
page_aligned(uint64_t value)
{
	return (value % ERX_PAGE_SIZE == 0);
}

bool
erx_exec_record_placed(uint64_t record)
{
	return (record != 0 && page_aligned(record));
}

erx_exec_release_verdict_t
erx_exec_release_check(uint64_t record, erx_exec_range_t loader, erx_exec_range_t own)
{
	uint64_t end;

	if (!erx_exec_record_placed(record))
		return (ERX_EXEC_RELEASE_RECORD);
	if (!page_aligned(loader.address) || !page_aligned(loader.size))
		return (ERX_EXEC_RELEASE_UNALIGNED);
	if (loader.size == 0)
		return (ERX_EXEC_RELEASE_EMPTY);
	if (__builtin_add_overflow(loader.address, loader.size, &end))
		return (ERX_EXEC_RELEASE_OVERFLOW);
	/* own is the executable's link's, so its end is the link's and needs no check. */
	if (loader.address < own.address + own.size && own.address < end)
		return (ERX_EXEC_RELEASE_OVERLAP);
	return (ERX_EXEC_RELEASE_GO);
}

bool
erx_exec_release(uint64_t record, erx_exec_range_t own)
{
	erx_exec_record_t fields = { 0 };
	erx_exec_range_t loader;

	/* Each field the release uses is read once, here, and only from a placed record. */
	if (erx_exec_record_placed(record))
		fields = *(const erx_exec_record_t *)(uintptr_t)record;
	loader = (erx_exec_range_t){ .address = fields.loader_base, .size = fields.loader_size };
	return (erx_exec_release_check(record, loader, own) == ERX_EXEC_RELEASE_GO &&
	    erx_vm_release(ERX_CAP_SELF, loader.address, loader.size) == ERX_OK &&
	    erx_vm_release(ERX_CAP_SELF, record, ERX_PAGE_SIZE) == ERX_OK);
}
