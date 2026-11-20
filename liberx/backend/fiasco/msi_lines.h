/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_MSI_LINES_H
#define ERX_FIASCO_MSI_LINES_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/cdefs.h"

/*
 * The MSI frame's lines on Fiasco (docs/design-pcie.md, "The MSI frame on Fiasco"): the
 * range the manifest's msi_frame names, and the pure choice of an ERX_IRQ_MSI create's
 * line. The choice asks irq.c whether each line is held, so the IRQ objects' table stays
 * the one record of which lines are taken and an object's end frees its line by itself.
 * The host checks it (test/fixtures/fiasco_msi_driver.c).
 */

typedef struct erx_fiasco_msi_range {
	uint32_t	first;	/* the interrupt id of the frame's first line */
	uint32_t	count;	/* how many lines the frame serves, 0 on a platform without one */
} erx_fiasco_msi_range_t;

/* Whether an object holds the line, an interrupt id of the range. */
typedef bool	(*erx_fiasco_msi_held_t)(uint32_t line, const void *context);

/*
 * The lowest line of the range that held says no object holds, in *line. A range of
 * no lines is ERX_ENOTSUP, since the platform has no frame; a range whose every line is
 * held, ERX_ELIMIT. The manifest's reader bounds first and count to
 * msi_frame_lines_max, so first + count does not overflow.
 */
int	erx_fiasco_msi_line_take(erx_fiasco_msi_range_t range, erx_fiasco_msi_held_t held, const void *context,
	    uint32_t *line) ERX_WARN_UNUSED_RESULT;

#endif
