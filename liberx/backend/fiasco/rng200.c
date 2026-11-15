/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/dt.h"
#include "erx/core/rng200.h"
#include "erx/explicit_bzero.h"
#include "erx/hw/rng200.h"
#include "erx/mmio.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/rng200.h"
#include "liberx/backend/fiasco/vm.h"

static bool	rng200_map(erx_dt_window_t, erx_mmio_t *);
static bool	rng200_start(erx_mmio_t);

erx_board_seed_t
erx_fiasco_rng200_read(const erx_dt_t *tree, const char *path, erx_dt_window_t window, erx_rng200_read_t *read)
{
	erx_rng200_action_t action;
	uint32_t count, word = 0, take;
	erx_mmio_t device;

	*read = (erx_rng200_read_t){ .words = 0 };
	/* With no counter frequency the clock stands still, and the wait would never end. */
	if (erx_fiasco_counter_hz() == 0)
		return (ERX_BOARD_UNREADABLE);
	switch (erx_dt_registers(tree, path, ERX_RNG200_COMPATIBLE, window)) {
	case ERX_DT_REGS_NONE:
		return (ERX_BOARD_NONE);
	case ERX_DT_REGS_MALFORMED:
	case ERX_DT_REGS_OTHER:
		return (ERX_BOARD_UNREADABLE);
	case ERX_DT_REGS_OK:
		break;
	}
	if (!rng200_map(window, &device) || !rng200_start(device))
		return (ERX_BOARD_UNREADABLE);
	*read = erx_rng200_start(erx_fiasco_clock_ns());
	for (;;) {
		if (!erx_rng200_fifo_count_read(device, &count))
			return (ERX_BOARD_UNREADABLE);
		action = erx_rng200_next(read, erx_rng200_fifo_count_count_get(count), erx_fiasco_clock_ns(), &take);
		if (action != ERX_RNG200_POLL && action != ERX_RNG200_TAKE)
			break;
		/* FIFO_DATA lies below FIFO_COUNT in the window, so its read cannot fail where the count's did not. */
		for (; take > 0 && erx_rng200_fifo_data_read(device, &word); take--)
			erx_rng200_take(read, word);
	}
	erx_explicit_bzero(&word, sizeof(word));
	return (action == ERX_RNG200_DONE ? ERX_BOARD_READ : ERX_BOARD_TIMED_OUT);
}

/*
 * Maps the page that holds the generator's window. The registers it reads lie in that
 * page: a window running past it is cut at the page's end, and the accessors refuse a
 * register outside what is left.
 */
static bool
rng200_map(erx_dt_window_t window, erx_mmio_t *device)
{
	const uint64_t offset = window.base & (ERX_PAGE_SIZE - 1);
	uintptr_t page;

	if (erx_fiasco_vm_device_page(window.base - offset, &page) != ERX_OK)
		return (false);
	device->base = (volatile uint8_t *)(page + offset);
	device->length = (size_t)(window.size < ERX_PAGE_SIZE - offset ? window.size : ERX_PAGE_SIZE - offset);
	return (true);
}

/*
 * Starts the generator if it is stopped. CTRL's bits above bit 0 rest on one source each
 * (hw/svd/rng200/rng200.svd), so a CTRL that holds any of them with bit 0 clear is not
 * written back: the read is refused rather than left to wait on a generator it cannot start.
 */
static bool
rng200_start(erx_mmio_t device)
{
	uint32_t ctrl;

	if (!erx_rng200_ctrl_read(device, &ctrl))
		return (false);
	if (erx_rng200_ctrl_rbg_en_get(ctrl) == 1)
		return (true);
	return (erx_rng200_ctrl_rbg_en_set(ctrl, 1, &ctrl) && erx_rng200_ctrl_write(device, ctrl));
}
