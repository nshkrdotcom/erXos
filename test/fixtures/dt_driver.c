/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/dt.c for test/host/dt_test.rb. Usage: dt_driver TREE
 * [PREFIX]. The tree's bytes, or only their first PREFIX bytes, go in a
 * buffer of exactly that length, so a read past them is a sanitizer
 * report. The first output line is the acceptance: "accept ok" or "accept
 * REASON". Then each query on standard input gets one line:
 *
 *   device PATH node|pcie [DMA_LIMIT]
 *     -> device DMA coherent C range CPU BUS LAST mac M
 *   fb PATH COMPATIBLE WINDOW_BASE WINDOW_SIZE
 *     -> fb STATUS BASE LENGTH WIDTHxHEIGHT STRIDE FORMAT
 *   seeds
 *     -> seeds rng-seed LENGTH HEX kaslr-seed LENGTH HEX, HEX - for an absent seed
 *   regs PATH COMPATIBLE WINDOW_BASE WINDOW_SIZE
 *     -> regs STATUS
 *   intx PATH BUS DEVICE FUNCTION PIN
 *     -> intx STATUS LINE
 *   bridge PATH
 *     -> bridge STATUS buses FIRST LAST, then window PCI CPU SIZE FLAGS for each
 *        window of a size other than 0
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/dt.h"

static const char *const dma_names[] = { "ok", "no_node", "coherence", "cells", "malformed", "ranges" };
static const char *const fb_names[] = { "ok", "none", "ambiguous", "malformed", "unsupported", "outside" };
static const char *const regs_names[] = { "ok", "none", "malformed", "other" };
static const char *const intx_names[] = { "ok", "no_node", "none", "malformed", "unsupported" };
static const char *const bridge_names[] = { "ok", "no_node", "cells", "malformed", "ranges" };

static void
device_print(const erx_dt_t *tree, const char *path, const char *row, const char *dma_limit)
{
	erx_dt_device_t facts;

	erx_dt_device(tree, path, strcmp(row, "pcie") == 0 ? ERX_DT_ROW_PCIE : ERX_DT_ROW_NODE,
	    dma_limit == NULL ? 0 : strtoull(dma_limit, NULL, 0), &facts);
	printf("device %s coherent %d range 0x%" PRIx64 " 0x%" PRIx64 " 0x%" PRIx64 " mac ", dma_names[facts.dma],
	    facts.coherent, facts.cpu, facts.bus, facts.last);
	if (facts.mac_status == ERX_DT_MAC_OK)
		printf("%02x:%02x:%02x:%02x:%02x:%02x\n", facts.mac[0], facts.mac[1], facts.mac[2], facts.mac[3],
		    facts.mac[4], facts.mac[5]);
	else
		printf("none\n");
}

static void
fb_print(const erx_dt_t *tree, const char *path, const char *compatible, const char *base, const char *size)
{
	erx_dt_window_t window = { strtoull(base, NULL, 0), strtoull(size, NULL, 0) };
	erx_dt_framebuffer_t fb;
	const char *format;

	erx_dt_framebuffer(tree, path, compatible, window, &fb);
	format = fb.status == ERX_DT_FB_OK ? erx_dt_fb_format_name(fb.format) : "-";
	printf("fb %s 0x%" PRIx64 " 0x%" PRIx64 " %ux%u %u %s %u\n", fb_names[fb.status], fb.base, fb.length,
	    fb.width, fb.height, fb.stride, format, fb.bits_per_pixel);
}

static void
seeds_print(const erx_dt_t *tree)
{
	static const char *const names[ERX_DT_SEEDS] = ERX_DT_SEED_NAMES;
	erx_dt_seeds_t seeds;

	erx_dt_seeds(tree, &seeds);
	printf("seeds");
	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++) {
		printf(" %s %zu ", names[seed], seeds.length[seed]);
		if (seeds.length[seed] == 0)
			printf("-");
		for (size_t at = 0; at < seeds.length[seed]; at++)
			printf("%02x", seeds.bytes[seed][at]);
	}
	printf("\n");
}

static void
regs_print(const erx_dt_t *tree, const char *path, const char *compatible, const char *base, const char *size)
{
	const erx_dt_window_t window = { strtoull(base, NULL, 0), strtoull(size, NULL, 0) };

	printf("regs %s\n", regs_names[erx_dt_registers(tree, path, compatible, window)]);
}

static void
intx_print(const erx_dt_t *tree, char *const words[5])
{
	const erx_pcie_place_t place = { (uint8_t)strtoul(words[1], NULL, 0), (uint8_t)strtoul(words[2], NULL, 0),
		(uint8_t)strtoul(words[3], NULL, 0), (uint8_t)strtoul(words[4], NULL, 0) };
	erx_dt_intx_status_t status;
	uint32_t line;

	status = erx_dt_intx(tree, words[0], &place, &line);
	printf("intx %s %" PRIu32 "\n", intx_names[status], line);
}

static void
bridge_print(const erx_dt_t *tree, const char *path)
{
	erx_pcie_bridge_t bridge;
	erx_dt_bridge_status_t status;
	size_t i;

	memset(&bridge, 0xa5, sizeof(bridge));
	status = erx_dt_bridge(tree, path, &bridge);
	printf("bridge %s buses %u %u", bridge_names[status], bridge.bus_first, bridge.bus_last);
	for (i = 0; i < ERX_PCIE_WINDOWS_MAX; i++)
		if (bridge.windows[i].size != 0)
			printf(" window 0x%" PRIx64 " 0x%" PRIx64 " 0x%" PRIx64 " %u", bridge.windows[i].pci,
			    bridge.windows[i].cpu, bridge.windows[i].size, bridge.windows[i].flags);
	for (i = 0; i < ERX_PCIE_WINDOWS_MAX; i++)
		if (bridge.inbound[i].size != 0)
			printf(" inbound 0x%" PRIx64 " 0x%" PRIx64 " 0x%" PRIx64 " %u", bridge.inbound[i].pci,
			    bridge.inbound[i].cpu, bridge.inbound[i].size, bridge.inbound[i].flags);
	printf("\n");
}

int
main(int argc, char **argv)
{
	char line[2048], *words[7], *save;
	unsigned char *bytes;
	const char *reason;
	erx_dt_t tree;
	FILE *file;
	long size;
	size_t length;
	int count;

	if (argc < 2 || (file = fopen(argv[1], "rb")) == NULL || fseek(file, 0, SEEK_END) != 0 ||
	    (size = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0)
		return (2);
	length = argc > 2 ? strtoul(argv[2], NULL, 0) : (size_t)size;
	if (length > (size_t)size || (bytes = malloc(length == 0 ? 1 : length)) == NULL ||
	    fread(bytes, 1, length, file) != length)
		return (2);
	fclose(file);

	reason = erx_dt_accept(bytes, length, &tree);
	printf("accept %s memory %u\n", reason == NULL ? "ok" : reason, tree.memory_count);
	while (fgets(line, sizeof(line), stdin) != NULL) {
		count = 0;
		for (words[0] = strtok_r(line, " \n", &save); words[count] != NULL && count < 6;)
			words[++count] = strtok_r(NULL, " \n", &save);
		if ((count == 3 || count == 4) && strcmp(words[0], "device") == 0)
			device_print(&tree, words[1], words[2], count == 4 ? words[3] : NULL);
		else if (count == 5 && strcmp(words[0], "fb") == 0)
			fb_print(&tree, words[1], words[2], words[3], words[4]);
		else if (count == 1 && strcmp(words[0], "seeds") == 0)
			seeds_print(&tree);
		else if (count == 5 && strcmp(words[0], "regs") == 0)
			regs_print(&tree, words[1], words[2], words[3], words[4]);
		else if (count == 6 && strcmp(words[0], "intx") == 0)
			intx_print(&tree, &words[1]);
		else if (count == 2 && strcmp(words[0], "bridge") == 0)
			bridge_print(&tree, words[1]);
		else
			return (2);
	}
	free(bytes);
	return (0);
}
