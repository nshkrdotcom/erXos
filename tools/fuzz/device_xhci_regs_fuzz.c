/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The device NIF's resolution of a register layout (erx_device_resolve in
 * otp/erts/emulator/nifs/erxos/erx_device_core.h) over xHCI's table against a hostile
 * controller, whose capability registers and extended-capability list are what it says. The
 * input is a u16, the window's bytes past the table's own 0x20, then the register file from
 * the window's start, zero past the input's end.
 *
 * The harness checks that every read lies inside the window at an offset aligned to its
 * width, that the resolution ends within its sources and ERX_DEVICE_LIST_ENTRIES_MAX list
 * entries, and that when it is done, every element of every register lies wholly inside the
 * window, aligned, no register has more elements than its table count, a capability's
 * instances lie in list order, and an index past the elements is refused.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx_device_core.h"

#define WINDOW_MAX	0x4000u

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void
check(bool condition)
{
	if (!condition)
		abort();
}

static uint64_t
word_at(const uint8_t *file, uint64_t offset, uint8_t width)
{
	uint64_t word = 0;

	for (unsigned byte = 0; byte < width / 8u; byte++)
		word |= (uint64_t)file[offset + byte] << (8 * byte);
	return (word);
}

/* Every element of every register where the layout puts it: inside, aligned, and nothing past the count. */
static void
check_layout(const erx_device_peripheral_t *xhci, const erx_device_layout_t *layout, uint64_t size)
{
	uint64_t offset;

	for (uint32_t index = 0; index < xhci->register_count; index++) {
		const erx_device_register_t *const reg = &xhci->registers[index];
		const uint32_t elements = layout->elements[index];

		check(elements <= reg->count);
		for (uint32_t at = 0; at < elements; at++) {
			check(erx_device_layout_offset(xhci, layout, reg, reg->count > 1, at, &offset));
			check(offset % (reg->width / 8u) == 0 && offset + reg->width / 8u <= size);
		}
		check(!erx_device_layout_offset(xhci, layout, reg, reg->count > 1, elements, &offset));
	}
	for (uint32_t base = 0; base < xhci->base_count; base++) {
		const erx_device_base_t *const cluster = &xhci->bases[base];

		for (uint32_t at = 1; cluster->capability != 0 && at < cluster->instances; at++)
			check(layout->slot[cluster->first + at] == 0 ||
			    layout->slot[cluster->first + at] > layout->slot[cluster->first + at - 1]);
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static const erx_device_peripheral_t *xhci;
	static uint8_t file[WINDOW_MAX];
	erx_device_layout_t layout;
	erx_device_resolve_t step;
	uint64_t window;
	uint32_t reads = 0;

	if (xhci == NULL)
		xhci = erx_device_peripheral_find("xhci", 4);
	check(xhci != NULL);
	if (size < 2)
		return (0);
	window = xhci->window_size + (data[0] | (uint64_t)data[1] << 8) % (WINDOW_MAX - xhci->window_size + 1);
	memset(file, 0, sizeof(file));
	memcpy(file, data + 2, size - 2 < window ? size - 2 : window);
	erx_device_resolve_begin(xhci, window, &layout, &step);
	while (step.op == ERX_DEVICE_RESOLVE_READ) {
		check(++reads <= xhci->register_count + ERX_DEVICE_LIST_ENTRIES_MAX);
		check(step.offset % (step.width / 8u) == 0 && step.offset + step.width / 8u <= window);
		erx_device_resolve_step(xhci, &layout, &step, word_at(file, step.offset, step.width));
	}
	check(step.op == ERX_DEVICE_RESOLVE_DONE || step.op == ERX_DEVICE_RESOLVE_REFUSED);
	if (step.op == ERX_DEVICE_RESOLVE_DONE)
		check_layout(xhci, &layout, window);
	return (0);
}
