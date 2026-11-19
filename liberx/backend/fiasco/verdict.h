/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_VERDICT_H
#define ERX_FIASCO_VERDICT_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/pack.h"

/*
 * The root's verdicts on the boot archive's files, as erXos's kernel keeps them
 * (docs/design-kernel.md, "Verdicts"; docs/design-fiasco.md, "The call table",
 * erx_image_map): one byte per entry, unchecked, good or refused. A verdict moves only
 * from unchecked to final, so each file is hashed once however many maps and checks
 * read it, and a refused file is refused at once from then on. The bytes are this
 * module's alone. Any thread of the root may check a file and any may read a verdict:
 * a verdict is stored only after its file's check, with release order, and read with
 * acquire order. The archive never changes, so two threads that check one file at once
 * both hash it and store the same verdict, and a good file's bytes stay the bytes its
 * check read, since the archive is read-only to the root.
 */
typedef struct erx_fiasco_verdicts {
	_Atomic uint8_t	entry[ERX_PACK_ENTRIES_MAX];
} erx_fiasco_verdicts_t;

/*
 * ERX_OK when entry index of view, an archive erx_pack_open accepted, has a good
 * verdict, ERX_ECORRUPT when it has a refused one, hashing its file with hasher in the
 * calling thread first when it is unchecked; ERX_ERANGE for an index past the archive.
 */
int	erx_fiasco_verdict_check(erx_fiasco_verdicts_t *verdicts, const erx_pack_view_t *view, uint32_t index,
	    erx_blake3_ctx_t *hasher) ERX_WARN_UNUSED_RESULT;
/* Whether entry index has a good verdict; false past the table. Reads, never hashes. */
bool	erx_fiasco_verdict_good(const erx_fiasco_verdicts_t *verdicts, uint32_t index);

#endif /* ERX_FIASCO_VERDICT_H */
