/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the domain library's boot view (liberx/system/dom_boot_view.c),
 * run by test/host/dom_planner_test.rb: it builds the view from a packed
 * manifest's bytes, as tools/host/dom_plan.c does with no archive files,
 * and prints what /dev and the domain service read of it.
 *
 *   dom-view MANIFEST [framebuffer|pci]
 *
 * One line per catalogue entry, then one per service row, then one per
 * configured row that serves a display, with the display its creation puts
 * in its environment, then, for the configured row whose boot page carries
 * -erx_record system_image, that record's words after its form:
 *
 *   device INDEX unit=NAME compatible=STRING|none ranges=BASE+SIZE,... lines=LINE,... confined=0|1
 *   service INDEX name=NAME server=ROW|none interface=NUMBER
 *   display ROW name=NAME policy=NUMBER idle_dim_s=SECONDS idle_off_s=SECONDS
 *   system_image ROW LEN TREE_OFF TREE_LEN SALT ROOT
 *
 * numbers in hexadecimal for ranges and decimal elsewhere. A view the
 * library refuses prints `refused REASON` alone. A malformed input prints
 * nothing and exits 2.
 *
 * With framebuffer, it prints instead, for each framebuffer row's entry,
 * its ranges as the view builds it, then after the root places a
 * framebuffer that straddles the end of the row's window
 * (erx_dom_view_framebuffer), then after it places one at
 * FRAMEBUFFER_OFFSET into the window, FRAMEBUFFER_LENGTH long, then after it
 * places the first again, which must take back the second's range:
 *
 *   framebuffer INDEX built ranges=BASE+SIZE,...
 *   framebuffer INDEX outside placed=0|1 ranges=BASE+SIZE,...
 *   framebuffer INDEX inside placed=0|1 ranges=BASE+SIZE,... offset=OFFSET size=SIZE
 *   framebuffer INDEX again placed=0|1 ranges=BASE+SIZE,...
 *
 * numbers in hexadecimal.
 *
 * With pci, it prints instead each PCIe host bridge's catalogue as the view
 * builds it, then the report the library takes for it once the root has
 * joined the tree's facts (erx_dom_view_bridge), a window moving PCI
 * PCI_WINDOW_PCI to CPU PCI_WINDOW_CPU over buses 0 and 1: one ready
 * function at each pci row's place below the bridge, of the row's identity
 * and its place's pin, each with one 4 KiB 64-bit BAR placed in turn from
 * the window's start (erx_dom_lib_pci_report), and the same report on the
 * catalogue joined instead to a tree the reader refused, with each layout the
 * report left, its placing state, latest state and confirmation; then whether a
 * give finds each pci row's function in the view's catalogues (erx_dom_pci_given),
 * with its first BAR's CPU range; then each pci row's mode writes (print_modes):
 *
 *   bridge INDEX row=ROW closed=0|1 places=BUS.DEVICE.FUNCTION/PIN,...
 *   report ROW status=STATUS field=FIELD|none
 *   layout ROW BUS.DEVICE.FUNCTION placed=STATE state=STATE confirmed=0|1
 *   refused ROW status=STATUS field=FIELD|none
 *   given INDEX cpu=BASE+SIZE|none
 *   mode INDEX unheld=S held=S mode=MODE past=S unconfirmed=S off=S other=S
 *
 * numbers in hexadecimal for ranges and decimal elsewhere.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/boot_words.h"
#include "erx/dom_lib.h"
#include "liberx/backend/core/boot_manifest.h"
#include "input.h"

static void
print_ranges(const erx_dom_device_entry_t *entry)
{
	printf(" ranges=");
	for (uint32_t at = 0; at < entry->nranges; at++)
		printf("%s0x%" PRIx64 "+0x%" PRIx64, at == 0 ? "" : ",", entry->ranges[at].base,
		    entry->ranges[at].size);
}

static void
print_device(uint32_t index, const erx_dom_device_entry_t *entry)
{
	printf("device %" PRIu32 " unit=%.*s compatible=%s", index, (int)entry->unit_name_len,
	    entry->unit_name, entry->compatible == NULL ? "none" : entry->compatible);
	print_ranges(entry);
	if (entry->selector == ERX_MF_SELECTOR_PCI)
		printf(" bridge=%" PRIu32 " place=%u.%u.%u role=%s peripheral=%s", entry->bridge, entry->bus,
		    entry->device, entry->function, entry->role_word == NULL ? "none" : entry->role_word,
		    entry->peripheral == NULL ? "none" : entry->peripheral);
	printf(" lines=");
	for (uint32_t at = 0; at < entry->nlines; at++)
		printf("%s%" PRIu32, at == 0 ? "" : ",", entry->lines[at]);
	printf(" confined=%d\n", entry->confined ? 1 : 0);
}

#define FRAMEBUFFER_OFFSET	0x400u
#define FRAMEBUFFER_LENGTH	0x2000u
#define PCI_WINDOW_PCI		UINT64_C(0xc0000000)
#define PCI_WINDOW_CPU		UINT64_C(0x600000000)

/*
 * Each framebuffer row's ranges as built and after each of two placements, through tables,
 * the catalogue the view reads, as the root places it: the first framebuffer's last page lies
 * past the row's window, the second lies inside it.
 */
static void
print_framebuffers(const erx_dom_view_t *view, const erx_dom_boot_tables_t *tables)
{
	for (uint32_t index = 0; index < view->ndevices; index++) {
		erx_dom_device_entry_t *const entry = &tables->devices[index];
		const erx_dt_framebuffer_t outside = { .status = ERX_DT_FB_OK,
		    .base = entry->window.base + entry->window.size - ERX_PAGE_SIZE, .length = FRAMEBUFFER_LENGTH,
		    .width = 64, .height = 32, .stride = 256 };
		const erx_dt_framebuffer_t inside = { .status = ERX_DT_FB_OK,
		    .base = entry->window.base + FRAMEBUFFER_OFFSET, .length = FRAMEBUFFER_LENGTH,
		    .width = 64, .height = 32, .stride = 256 };
		bool placed;

		if (entry->role != ERX_MF_DEVICE_ROLE_FRAMEBUFFER)
			continue;
		printf("framebuffer %" PRIu32 " built", index);
		print_ranges(entry);
		placed = erx_dom_view_framebuffer(entry, &outside, "a8r8g8b8");
		printf("\nframebuffer %" PRIu32 " outside placed=%d", index, placed);
		print_ranges(entry);
		placed = erx_dom_view_framebuffer(entry, &inside, "a8r8g8b8");
		printf("\nframebuffer %" PRIu32 " inside placed=%d", index, placed);
		print_ranges(entry);
		printf(" offset=0x%" PRIx64 " size=0x%" PRIx64 "\n", entry->offset, entry->size);
		placed = erx_dom_view_framebuffer(entry, &outside, "a8r8g8b8");
		printf("framebuffer %" PRIu32 " again placed=%d", index, placed);
		print_ranges(entry);
		printf("\n");
	}
}

static void
print_service(uint32_t index, const erx_dom_service_t *service)
{
	printf("service %" PRIu32 " name=%.*s server=", index, (int)service->name_len, service->name);
	if (service->server == ERX_MF_NONE)
		printf("none");
	else
		printf("%" PRIu32, service->server);
	printf(" interface=%" PRIu32 "\n", service->interface);
}

/* The system window holder's -erx_record system_image words, as its creation writes them. */
static bool
print_system_image(const erx_dom_lib_t *lib)
{
	char words[ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX];
	size_t used;

	if (lib->system_image_holder == 0)
		return (true);
	if ((used = erx_boot_system_image_words(&lib->system_image, lib->record_volume, words, sizeof(words))) == 0)
		return (false);
	printf("system_image %" PRIu32, lib->system_image_holder - 1);
	for (size_t at = sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("system_image"); at < used; at += strlen(words + at) + 1)
		printf(" %s", words + at);
	printf("\n");
	return (true);
}

/* The pin a closed bridge lists for entry's place, or 1 (INTA) on an open bridge. */
static uint8_t
pci_pin(const erx_dom_pci_bridge_t *bridge, const erx_dom_device_entry_t *entry)
{
	for (uint32_t at = 0; at < ERX_PCIE_CLOSED_MAX; at++) {
		const erx_pcie_place_t *const place = &bridge->facts.places[at];

		if (place->bus == entry->bus && place->device == entry->device && place->function == entry->function)
			return (place->pin);
	}
	return (1);
}

/*
 * The same report on a copy of the bridge's catalogue joined to a tree the
 * reader refused, which takes no report.
 */
static void
pci_refused(erx_dom_lib_t *lib, uint32_t at, const erx_pcie_function_t *report, uint32_t count)
{
	const erx_dom_pci_bridge_t kept = lib->pci_bridges[at];
	const erx_pcie_bridge_t none = { 0 };
	erx_dom_pci_refusal_t refusal = { .field = "none" };

	lib->pci_bridges[at] = (erx_dom_pci_bridge_t){ .facts = kept.facts };
	erx_dom_view_bridge(&lib->pci_bridges[at], &none, ERX_DT_BRIDGE_MALFORMED);
	printf("refused %" PRIu32 " status=%d field=%s\n", kept.facts.index,
	    (int)erx_dom_lib_pci_report(lib, kept.facts.index, report, count, &refusal), refusal.field);
	lib->pci_bridges[at] = kept;
}

/*
 * The mode writes of pci row index (erx_dom_lib_pci_mode), the library left as
 * it was: a raise with no holder; with a holder, a raise to mastering and the
 * mode it leaves, a mode past the set, a raise with the function's layout
 * unconfirmed, and the lowering; and a write to its bridge's row, no pci row.
 */
static void
print_modes(erx_dom_lib_t *lib, uint32_t index)
{
	erx_dom_device_t *const record = &lib->device_records[index];
	const erx_dom_device_t kept = *record;
	erx_dom_pci_bridge_t *bridge = NULL;
	int unheld, held, past, unconfirmed, off, other;
	unsigned int mode;

	for (uint32_t at = 0; at < lib->view.npci_bridges; at++) {
		if (lib->pci_bridges[at].facts.index == lib->view.devices[index].bridge)
			bridge = &lib->pci_bridges[at];
	}
	unheld = (int)erx_dom_lib_pci_mode(lib, index, ERX_PCIE_MODE_DECODING);
	record->holder = 1;
	held = (int)erx_dom_lib_pci_mode(lib, index, ERX_PCIE_MODE_MASTERING);
	mode = record->setting.mode;
	past = (int)erx_dom_lib_pci_mode(lib, index, ERX_PCIE_MODE_MASTERING + 1);
	unconfirmed = -2;
	if (bridge != NULL && bridge->nlayouts > 0) {
		const erx_dom_pci_bridge_t confirmed = *bridge;

		for (uint32_t at = 0; at < bridge->nlayouts; at++)
			bridge->layouts[at].confirmed = false;
		unconfirmed = (int)erx_dom_lib_pci_mode(lib, index, ERX_PCIE_MODE_DECODING);
		*bridge = confirmed;
	}
	off = (int)erx_dom_lib_pci_mode(lib, index, ERX_PCIE_MODE_OFF);
	other = (int)erx_dom_lib_pci_mode(lib, lib->view.devices[index].bridge, ERX_PCIE_MODE_OFF);
	printf("mode %" PRIu32 " unheld=%d held=%d mode=%u past=%d unconfirmed=%d off=%d other=%d\n", index, unheld,
	    held, mode, past, unconfirmed, off, other);
	*record = kept;
}

static void
print_bridges(erx_dom_lib_t *lib)
{
	const erx_pcie_bridge_t tree = { .bus_first = 0, .bus_last = 1,
	    .windows = { { .pci = PCI_WINDOW_PCI, .cpu = PCI_WINDOW_CPU, .size = 0x40000000 } } };
	erx_pcie_function_t report[ERX_PCIE_FUNCTIONS_MAX];
	const erx_pcie_bridge_t *facts;
	erx_dom_pci_refusal_t refusal;
	erx_dom_range_t cpu;
	unsigned int vendor, device_id;
	uint32_t count;

	for (uint32_t at = 0; at < lib->view.npci_bridges; at++) {
		erx_dom_pci_bridge_t *const bridge = &lib->pci_bridges[at];

		printf("bridge %" PRIu32 " row=%" PRIu32 " closed=%d places=", at, bridge->facts.index,
		    (bridge->facts.flags & ERX_PCIE_BRIDGE_CLOSED) != 0 ? 1 : 0);
		for (uint32_t place = 0; place < ERX_PCIE_CLOSED_MAX && bridge->facts.places[place].bus != 0; place++)
			printf("%s%u.%u.%u/%u", place == 0 ? "" : ",", bridge->facts.places[place].bus,
			    bridge->facts.places[place].device, bridge->facts.places[place].function,
			    bridge->facts.places[place].pin);
		printf("\n");
		erx_dom_view_bridge(bridge, &tree, ERX_DT_BRIDGE_OK);
		count = 0;
		for (uint32_t index = 0; index < lib->view.ndevices && count < ERX_PCIE_FUNCTIONS_MAX; index++) {
			const erx_dom_device_entry_t *const entry = &lib->view.devices[index];

			if (entry->selector != ERX_MF_SELECTOR_PCI || entry->bridge != bridge->facts.index ||
			    entry->compatible == NULL || sscanf(entry->compatible, "pci%4x,%4x", &vendor, &device_id) != 2)
				continue;
			report[count] = (erx_pcie_function_t){ .bridge = bridge->facts.index, .bus = entry->bus,
			    .device = entry->device, .function = entry->function, .state = ERX_PCIE_STATE_READY,
			    .vendor = (uint16_t)vendor, .device_id = (uint16_t)device_id, .pin = pci_pin(bridge, entry),
			    .bars = { { .kind = ERX_PCIE_BAR_MEMORY, .flags = ERX_PCIE_BAR_ADDR64 | ERX_PCIE_BAR_PLACED,
			    .size_log2 = 12, .address = PCI_WINDOW_PCI + (uint64_t)count * ERX_PAGE_SIZE } } };
			count++;
		}
		refusal = (erx_dom_pci_refusal_t){ .field = "none" };
		printf("report %" PRIu32 " status=%d field=%s\n", bridge->facts.index,
		    (int)erx_dom_lib_pci_report(lib, bridge->facts.index, report, count, &refusal), refusal.field);
		for (uint32_t layout = 0; layout < bridge->nlayouts; layout++)
			printf("layout %" PRIu32 " %u.%u.%u placed=%u state=%u confirmed=%d\n", bridge->facts.index,
			    bridge->layouts[layout].record.bus, bridge->layouts[layout].record.device,
			    bridge->layouts[layout].record.function, bridge->layouts[layout].record.state,
			    bridge->layouts[layout].state, bridge->layouts[layout].confirmed ? 1 : 0);
		pci_refused(lib, at, report, count);
	}
	for (uint32_t index = 0; index < lib->view.ndevices; index++) {
		const erx_dom_device_entry_t *const entry = &lib->view.devices[index];
		const erx_dom_pci_layout_t *layout;

		if (entry->selector != ERX_MF_SELECTOR_PCI)
			continue;
		layout = erx_dom_pci_given(lib->view.pci_bridges, lib->view.npci_bridges, entry, &facts);
		if (layout != NULL && erx_dom_pci_bar_cpu(facts, &layout->record.bars[0], &cpu))
			printf("given %" PRIu32 " cpu=0x%" PRIx64 "+0x%" PRIx64 "\n", index, cpu.base, cpu.size);
		else
			printf("given %" PRIu32 " cpu=none\n", index);
	}
	for (uint32_t index = 0; index < lib->view.ndevices; index++) {
		if (lib->view.devices[index].selector == ERX_MF_SELECTOR_PCI)
			print_modes(lib, index);
	}
}

int
main(int argc, char **argv)
{
	static erx_dom_lib_t lib;
	erx_manifest_view_t manifest;
	erx_abi_error_t error;
	erx_dom_boot_sizes_t sizes;
	erx_dom_boot_tables_t tables;
	const char *reason;
	uint8_t *bytes, *region;
	size_t length, region_len;

	if (argc < 2 || argc > 3 || (argc == 3 && strcmp(argv[2], "framebuffer") != 0 && strcmp(argv[2], "pci") != 0) ||
	    (bytes = erx_host_input_read(argv[1], &length)) == NULL ||
	    !erx_manifest_open(bytes, length, &manifest, &error))
		return (2);
	/* The tables in one page-aligned region, as the root lays them out. */
	sizes = erx_dom_view_sizes(&manifest, 0);
	if (!erx_dom_boot_layout(&sizes, 0, &tables, &region_len) || region_len > SIZE_MAX - 2 * ERX_PAGE_SIZE)
		return (2);
	region_len = (region_len + 2 * ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;
	if ((region = aligned_alloc(ERX_PAGE_SIZE, region_len)) == NULL ||
	    !erx_dom_boot_layout(&sizes, (uintptr_t)region, &tables, &region_len))
		return (2);
	memset(region, 0, region_len);
	if ((reason = erx_dom_view_build(&lib, &manifest, 0, &tables)) != NULL) {
		printf("refused %s\n", reason);
		return (fflush(stdout) == 0 ? 0 : 2);
	}
	if (argc == 3 && strcmp(argv[2], "pci") == 0) {
		print_bridges(&lib);
		return (fflush(stdout) == 0 ? 0 : 2);
	}
	if (argc == 3) {
		print_framebuffers(&lib.view, &tables);
		return (fflush(stdout) == 0 ? 0 : 2);
	}
	for (uint32_t index = 0; index < lib.view.ndevices; index++)
		print_device(index, &lib.view.devices[index]);
	for (uint32_t index = 0; index < lib.view.nservices; index++)
		print_service(index, &lib.view.services[index]);
	if (lib.view.apps.max != 0)
		printf("apps template=%" PRIu32 " first=%" PRIu32 " max=%" PRIu32 " memory=%" PRIu64 " principals=%" PRIu32 "\n",
		    lib.view.apps.template, lib.view.apps.first, lib.view.apps.max, lib.view.apps.memory, lib.view.nprincipals);
	for (uint32_t index = 0; index < lib.view.nconfigured; index++) {
		const erx_dom_display_t *display = &lib.view.configured[index].display;

		if (display->name_len != 0)
			printf("display %" PRIu32 " name=%.*s policy=%" PRIu32 " idle_dim_s=%" PRIu32 " idle_off_s=%" PRIu32 "\n",
			    index, (int)display->name_len, display->name, display->policy, display->idle_dim_s,
			    display->idle_off_s);
	}
	if (!print_system_image(&lib))
		return (2);
	return (fflush(stdout) == 0 ? 0 : 2);
}
