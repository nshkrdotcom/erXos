/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The device-tree reader's interrupt controller binding on AArch64, the
 * GIC's (docs/design-arch-aarch64.md, "Interrupt controller"): the line a
 * closed bus's INTx is routed to, from the three cells of a GIC interrupt
 * specifier, as FreeBSD decodes them (sys/arm/arm/gic.c:702-751,
 * gic_common.h:58-61). The first cell is the type, 0 for an SPI; the second
 * the number, an SPI from 0 to 987, whose interrupt id is 32 more; the third
 * the flags, whose low four bits are 4 for level-triggered, active high. An
 * INTx line is level-sensitive and an SPI cannot be active low, so only a
 * level-triggered, active-high SPI is an INTx line. Pure over the cells the
 * reader hands it, so the host tests and the fuzz target link it too.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/core/dt.h"

#define GIC_CELLS		3
#define GIC_TYPE_SPI		0
#define GIC_SPI_LAST		987
#define GIC_SPI_FIRST_ID	32
#define GIC_TRIGGER_MASK	0xf
#define GIC_LEVEL_HIGH		0x4

/* The platforms' interrupt controllers (docs/design-platforms.md, "Data model"). */
const char *const erx_dt_interrupt_controllers[] = { "arm,gic-400", "arm,gic-v3", NULL };

erx_dt_intx_status_t
erx_dt_interrupt_line(const uint32_t *cells, uint32_t count, uint32_t *line)
{
	if (count != GIC_CELLS)
		return (ERX_DT_INTX_UNSUPPORTED);
	if (cells[0] != GIC_TYPE_SPI || (cells[2] & GIC_TRIGGER_MASK) != GIC_LEVEL_HIGH)
		return (ERX_DT_INTX_UNSUPPORTED);
	if (cells[1] > GIC_SPI_LAST)
		return (ERX_DT_INTX_MALFORMED);
	*line = GIC_SPI_FIRST_ID + cells[1];
	return (ERX_DT_INTX_OK);
}
