/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_EXEC_RELEASE_H
#define LIBERX_EXEC_RELEASE_H

/*
 * The end of a loader's tenure (docs/design-programs.md, "The loader's
 * bootstrap", Release): an executable that erx_exec loaded starts with
 * program_arg's exec naming the exec record, and its start-up releases the
 * loader's span the record gives, then the record's page, before musl's
 * start runs any constructor. The record is the session's word, trusted as
 * the argument registers are, and a cross-check, not the authority: the
 * loader is a fixed-link task, so its span is a constant of its own link,
 * which the executable knows as erx_exec_loader(). The check keeps a bug of
 * the loader or the session from becoming a wrong release: it refuses a
 * span other than the linked loader's or one that meets the executable's
 * own image, and a record whose page lies in either.
 *
 * The decision is pure and builds on the host; erx_exec_release is the
 * effect around it. Neither uses thread-local storage or a musl function
 * that does, since musl's start has not run.
 */

#include <stdbool.h>
#include <stdint.h>

#include "liberx/exec/range.h"

/* What the check decides of a record and the span it gives. */
typedef enum erx_exec_release_verdict {
	ERX_EXEC_RELEASE_GO,		/* release the span, then the record's page */
	ERX_EXEC_RELEASE_RECORD,	/* the record's address is 0 or not a page boundary */
	ERX_EXEC_RELEASE_LOADER,	/* the span is not the linked loader's, or none is linked */
	ERX_EXEC_RELEASE_LOADER_IMAGE,	/* the loader's span meets the executable's own image */
	ERX_EXEC_RELEASE_RECORD_IMAGE,	/* the record's page meets the executable's own image */
	ERX_EXEC_RELEASE_RECORD_LOADER,	/* the record's page lies in the loader's span */
} erx_exec_release_verdict_t;

/*
 * The span of the loader erx_exec's image, in whole pages, as its link
 * placed it: in an executable's link, the build's constant from the
 * loader's link; in a fixed-link task, which no loader enters, size 0
 * (loader_none.c), which no record matches.
 */
erx_exec_range_t erx_exec_loader(void);

/* Whether a reader may copy the record at record: a page boundary that is not 0. */
bool	erx_exec_record_placed(uint64_t record);

/*
 * Decides the release of the record at record, whose loader span, copied
 * once out of it, is recorded, in a program whose own image is own and
 * whose linked loader is loader.
 */
erx_exec_release_verdict_t erx_exec_release_check(uint64_t record, erx_exec_range_t recorded,
	    erx_exec_range_t own, erx_exec_range_t loader);

/*
 * Copies the loader's span once out of the record at record, when the
 * record is placed, checks it, and releases it and then the record's page
 * from the calling program's space. False when the check refuses or the
 * space refuses either release; the caller then stops the program with
 * ERX_PROG_STATUS_RELEASE.
 */
bool	erx_exec_release(uint64_t record, erx_exec_range_t own, erx_exec_range_t loader);

#endif /* !LIBERX_EXEC_RELEASE_H */
