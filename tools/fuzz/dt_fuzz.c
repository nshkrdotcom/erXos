/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The device-tree reader, kernel/core/dt.c, over arbitrary bytes, handed
 * over in a buffer of exactly their length so that a read past them is an
 * AddressSanitizer report. An accepted view goes to erx_dt_device for
 * fixed paths, with and without a DMA limit, to erx_dt_framebuffer, to
 * erx_dt_registers, to erx_dt_intx for every pin of two places and to
 * erx_dt_bridge, and every
 * answer must keep the reader's promises: memory ranges within the bound and
 * ordered, no DMA facts beside a status other than ok, a framebuffer whose
 * pages lie in its window and whose rows fit its length, and no register
 * window confirmed for an empty row, no line beside a status other than
 * ok, nor one outside the GIC's SPIs, no DMA range reaching the limit, and
 * no bridge facts beside a status other than ok, nor a bus span reversed, a
 * record field the reader does not own changed, or a window that wraps,
 * follows an unused one, has a flag not of the ABI or meets the tree's RAM.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/dt.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static const char *const paths[] = {
	"/", "/dev", "/bus/dev", "/outer/inner/dev", "/pcie", "/virtio_mmio@a003e00", "/pcie@10000000",
	"/emmc2bus/mmc@7e340000", "/scb/ethernet@7d580000", "/scb/pcie@7d500000", "/n1/n2/n3/n4/n5/n6/n7/n8"
};

static void
device_check(const erx_dt_t *tree, const char *path, erx_dt_row_t row, uint64_t dma_limit)
{
	erx_dt_device_t facts;

	erx_dt_device(tree, path, row, dma_limit, &facts);
	if (facts.dma > ERX_DT_DMA_RANGES || facts.mac_status > ERX_DT_MAC_NONE)
		abort();
	if (facts.dma != ERX_DT_DMA_OK && (facts.coherent || facts.cpu != 0 || facts.bus != 0 || facts.last != 0))
		abort();
	if (facts.dma == ERX_DT_DMA_OK && facts.last < facts.cpu)
		abort();
	if (facts.dma == ERX_DT_DMA_OK && dma_limit != 0 &&
	    (facts.bus >= dma_limit || facts.last - facts.cpu >= dma_limit - facts.bus))
		abort();
	if (facts.mac_status == ERX_DT_MAC_OK && (facts.mac[0] & 1) != 0)
		abort();
}

static void
framebuffer_check(const erx_dt_t *tree, uint64_t base, uint64_t size)
{
	erx_dt_window_t window = { base, size };
	erx_dt_framebuffer_t fb;

	erx_dt_framebuffer(tree, "/chosen", "simple-framebuffer", window, &fb);
	if (fb.status > ERX_DT_FB_OUTSIDE)
		abort();
	if (fb.status != ERX_DT_FB_OK)
		return;
	if (erx_dt_fb_format_name(fb.format) == NULL || fb.length == 0 || size == 0 ||
	    (fb.base & ~(uint64_t)(ERX_PAGE_SIZE - 1)) < base ||
	    ((fb.base + (fb.length - 1)) | (ERX_PAGE_SIZE - 1)) > base + (size - 1) ||
	    (uint64_t)fb.stride * fb.height > fb.length || (uint64_t)fb.width * (fb.bits_per_pixel / 8) > fb.stride)
		abort();
}

/* A seed is either absent or at most ERX_DT_SEED_MAX bytes, not all of them zero. */
static void
seeds_check(const erx_dt_t *tree)
{
	erx_dt_seeds_t seeds;
	bool set;

	erx_dt_seeds(tree, &seeds);
	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++) {
		if (seeds.length[seed] > ERX_DT_SEED_MAX)
			abort();
		set = seeds.length[seed] == 0;
		for (size_t at = 0; at < seeds.length[seed]; at++)
			set = set || seeds.bytes[seed][at] != 0;
		if (!set)
			abort();
	}
}

/*
 * The reader confirms the RNG200's row, the Pi 4's, or refuses it; a row with an empty
 * window, which no range the reader takes equals, it never confirms.
 */
static void
registers_check(const erx_dt_t *tree)
{
	static const char path[] = "/soc/rng@7e104000", compatible[] = "brcm,bcm2711-rng200";

	(void)erx_dt_registers(tree, path, compatible, (erx_dt_window_t){ 0xfe104000, 0x28 });
	if (erx_dt_registers(tree, path, compatible, (erx_dt_window_t){ 0xfe104000, 0 }) == ERX_DT_REGS_OK)
		abort();
}

/*
 * Each pin of the Pi 4's closed place and of a place whose bits fill every field. A
 * line is present only on ok, and is an SPI's interrupt id, 32 to 1019.
 */
static void
intx_check(const erx_dt_t *tree, const char *path)
{
	static const erx_pcie_place_t places[] = { { 1, 0, 0, 0 }, { 0xff, 0x1f, 0x7, 0 } };
	erx_dt_intx_status_t status;
	erx_pcie_place_t place;
	uint32_t line;
	size_t p;

	for (p = 0; p < sizeof(places) / sizeof(places[0]); p++) {
		place = places[p];
		for (place.pin = 1; place.pin <= ERX_PCIE_PIN_MAX; place.pin++) {
			status = erx_dt_intx(tree, path, &place, &line);
			if (status > ERX_DT_INTX_UNSUPPORTED || (status != ERX_DT_INTX_OK && line != 0) ||
			    (status == ERX_DT_INTX_OK && (line < 32 || line > 1019)))
				abort();
		}
	}
}

/*
 * A bridge's facts are zero beside a status other than ok, and the fields the
 * manifest gives are untouched; on ok its buses are in order and its windows
 * lead, each with a range that does not wrap, over no RAM, and only the ABI's
 * flags.
 */
static void
bridge_check(const erx_dt_t *tree, const char *path)
{
	erx_pcie_bridge_t bridge;
	erx_dt_bridge_status_t status;
	uint64_t last;
	bool unused;
	uint32_t m;
	size_t i;

	memset(&bridge, 0xa5, sizeof(bridge));
	status = erx_dt_bridge(tree, path, &bridge);
	if (status > ERX_DT_BRIDGE_RANGES || bridge.index != 0xa5a5a5a5 || bridge.flags != 0xa5 ||
	    bridge.places[0].bus != 0xa5 || bridge.places[ERX_PCIE_CLOSED_MAX - 1].pin != 0xa5)
		abort();
	if (status != ERX_DT_BRIDGE_OK && (bridge.bus_first != 0 || bridge.bus_last != 0))
		abort();
	if (bridge.bus_first > bridge.bus_last)
		abort();
	unused = false;
	for (i = 0; i < ERX_PCIE_WINDOWS_MAX; i++) {
		if (bridge.windows[i].size == 0) {
			if (bridge.windows[i].pci != 0 || bridge.windows[i].cpu != 0 || bridge.windows[i].flags != 0)
				abort();
			unused = true;
			continue;
		}
		if (status != ERX_DT_BRIDGE_OK || unused || (bridge.windows[i].flags & ~ERX_PCIE_WINDOW_FLAGS_KNOWN) != 0 ||
		    (bridge.windows[i].flags & ERX_PCIE_WINDOW_IO) != 0 ||
		    __builtin_add_overflow(bridge.windows[i].pci, bridge.windows[i].size - 1, &last) ||
		    __builtin_add_overflow(bridge.windows[i].cpu, bridge.windows[i].size - 1, &last))
			abort();
		for (m = 0; m < tree->memory_count; m++)
			if (tree->memory[m].first <= last && bridge.windows[i].cpu <= tree->memory[m].last)
				abort();
	}
	/* Inbound windows the same, but for the RAM test: an inbound window may reach RAM. */
	unused = false;
	for (i = 0; i < ERX_PCIE_WINDOWS_MAX; i++) {
		if (bridge.inbound[i].size == 0) {
			if (bridge.inbound[i].pci != 0 || bridge.inbound[i].cpu != 0 || bridge.inbound[i].flags != 0)
				abort();
			unused = true;
			continue;
		}
		if (status != ERX_DT_BRIDGE_OK || unused || (bridge.inbound[i].flags & ~ERX_PCIE_WINDOW_FLAGS_KNOWN) != 0 ||
		    (bridge.inbound[i].flags & ERX_PCIE_WINDOW_IO) != 0 ||
		    __builtin_add_overflow(bridge.inbound[i].pci, bridge.inbound[i].size - 1, &last) ||
		    __builtin_add_overflow(bridge.inbound[i].cpu, bridge.inbound[i].size - 1, &last))
			abort();
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_dt_t tree;
	uint8_t *bytes;
	uint32_t i;
	size_t p;

	bytes = malloc(size == 0 ? 1 : size);
	if (bytes == NULL)
		return (0);
	memcpy(bytes, data, size);
	if (erx_dt_accept(bytes, size, &tree) == NULL) {
		if (tree.bytes != bytes || tree.size != size || tree.memory_count > ERX_DT_MEMORY_MAX)
			abort();
		for (i = 0; i < tree.memory_count; i++)
			if (tree.memory[i].last < tree.memory[i].first)
				abort();
		for (p = 0; p < sizeof(paths) / sizeof(paths[0]); p++) {
			device_check(&tree, paths[p], ERX_DT_ROW_NODE, 0);
			device_check(&tree, paths[p], ERX_DT_ROW_PCIE, 0);
			device_check(&tree, paths[p], ERX_DT_ROW_PCIE, 0x3c000000);
			bridge_check(&tree, paths[p]);
		}
		framebuffer_check(&tree, 0x7e000000, 0x400000);
		framebuffer_check(&tree, 0, UINT64_MAX);
		seeds_check(&tree);
		registers_check(&tree);
		intx_check(&tree, "/pcie");
		intx_check(&tree, "/scb/pcie@7d500000");
	} else if (tree.bytes != NULL || tree.memory_count != 0) {
		abort();
	}
	free(bytes);
	return (0);
}
