/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's effects on an xHCI controller the harness plays over a plain register
 * window (erx_device.c, docs/design-usb.md, "Install"): the record made by the first negotiate
 * call from the counts the capability registers give; one step a call, each answered ebusy, run
 * cleared, HCRST written only once the controller halts, nothing written while HCRST or CNR
 * stays set, then the install's registers in FreeBSD's order, each word from the table's fields
 * (an address low word then high, CRCR's cycle state, IMAN.IE with IP written 0, USBCMD's run
 * and INTE) over memory the install laid out, and ok once the controller runs; the next call
 * begins again. And the refusals before anything is written: too many scratchpad pages, a page
 * size without 4 KiB, memory past 4 GiB without AC64, and a numbered queue on the device.
 */

#include <sys/mman.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/hw/xhci.h"
#include "liberx/backend/api.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_trb_form.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define MEMORIES_MAX	16u
#define WINDOW_BYTES	0x4000u
#define DEVICE_MEMORY	(UINT64_C(1) << 20)
#define SLOT_SHIFT	28u
#define HIGH_BASE	(UINT64_C(1) << 40)
/* Where the harness's controller reports its movable clusters. */
#define OPERATIONAL	0x20u
#define RUNTIME		0x1000u
#define DOORBELLS	0x2000u
#define WRITES_MAX	64u

static uint8_t *memories[MEMORIES_MAX];
static uint64_t memory_sizes[MEMORIES_MAX];
static uint32_t memory_count;
static bool high_addresses;		/* erx_mem_dma_addr answers past 4 GiB */
static const erx_device_peripheral_t *xhci;
static uint8_t *window;
/* Every 32-bit store to the window, in order. */
static uint32_t write_offsets[WRITES_MAX], write_values[WRITES_MAX];
static uint32_t writes;

static uint64_t
make_memory(uint64_t size)
{
	void *bytes;

	CHECK(memory_count < MEMORIES_MAX && size % ERX_PAGE_SIZE == 0);
	bytes = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
	CHECK(bytes != MAP_FAILED);
	memories[memory_count] = bytes;
	memory_sizes[memory_count] = size;
	return (memory_count++);
}

int
erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr, uint64_t *mem)
{
	(void)budget;
	(void)resource;
	(void)base;
	(void)size;
	(void)attr;
	(void)mem;
	CHECK(false);
	return (ERX_ENOTSUP);
}

int
erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr)
{
	if (mem >= memory_count)
		return (ERX_EINVAL);
	if (offset >= memory_sizes[mem])
		return (ERX_ERANGE);
	*addr = (high_addresses ? HIGH_BASE : 0) + ((mem + 1) << SLOT_SHIFT) + offset;
	return (ERX_OK);
}

/* The objects an open maps, in order, each whole at its own mapping. */
static uint64_t maps[2];
static uint32_t maps_pushed, maps_done;

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	CHECK(space == ERX_CAP_SELF && addr == 0 && flags == 0 && maps_done < maps_pushed &&
	    size <= memory_sizes[maps[maps_done]]);
	*reserved = (uint64_t)(uintptr_t)memories[maps[maps_done]];
	return (ERX_OK);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	CHECK(space == ERX_CAP_SELF && maps_done < maps_pushed && mem == maps[maps_done] && addr == (uint64_t)(uintptr_t)memories[mem] &&
	    size <= memory_sizes[mem] && offset == 0 && prot == ERX_PROT_RW);
	maps_done++;
	return (ERX_OK);
}

/* Every map here succeeds, so no reservation is ever given back. */
int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	(void)addr;
	(void)size;
	CHECK(!"a map was refused");
	return (ERX_EINVAL);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq,
    erx_msi_message_t *message)
{
	(void)message;
	(void)budget;
	(void)resource;
	(void)kind;
	(void)selector;
	(void)irq;
	CHECK(false);
	return (ERX_ENOTSUP);
}

/* -------------------------------------------------------------------------------------------
 * The controller
 */


/* -------------------------------------------------------------------------------------------
 * The controller's window: plain memory, every 32-bit store logged
 */

uint8_t
erx_device_access_load8(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset < WINDOW_BYTES);
	return (at[offset]);
}

void
erx_device_access_store8(volatile uint8_t *at, uint64_t offset, uint8_t value)
{
	CHECK(at == window && offset < WINDOW_BYTES);
	at[offset] = value;
}

uint16_t
erx_device_access_load16(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset + 2 <= WINDOW_BYTES);
	return (*(volatile uint16_t *)(void *)(at + offset));
}

void
erx_device_access_store16(volatile uint8_t *at, uint64_t offset, uint16_t value)
{
	CHECK(at == window && offset + 2 <= WINDOW_BYTES);
	*(volatile uint16_t *)(void *)(at + offset) = value;
}

uint32_t
erx_device_access_load32(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset + 4 <= WINDOW_BYTES);
	return (*(volatile uint32_t *)(void *)(at + offset));
}

void
erx_device_access_store32(volatile uint8_t *at, uint64_t offset, uint32_t value)
{
	CHECK(at == window && offset + 4 <= WINDOW_BYTES && writes < WRITES_MAX);
	*(volatile uint32_t *)(void *)(at + offset) = value;
	write_offsets[writes] = (uint32_t)offset;
	write_values[writes++] = value;
}

/* xHCI's registers the NIF reaches are 32 bits wide or narrower. */
uint64_t
erx_device_access_load64(volatile uint8_t *at, uint64_t offset)
{
	(void)at;
	(void)offset;
	CHECK(false);
	return (0);
}

void
erx_device_access_store64(volatile uint8_t *at, uint64_t offset, uint64_t value)
{
	(void)at;
	(void)offset;
	(void)value;
	CHECK(false);
}

/* The window offset of register `name`: its cluster's base, as the harness reports it, plus its own. */
static uint32_t
offset_of(const char *name)
{
	static const uint32_t bases[] = { 0, OPERATIONAL, RUNTIME, DOORBELLS };
	const uint32_t found = erx_device_register_named(xhci, name);

	CHECK(found < xhci->register_count && xhci->registers[found].base < 4);
	return (bases[xhci->registers[found].base] + xhci->registers[found].offset);
}

static uint32_t *
reg(const char *name)
{
	return ((uint32_t *)(void *)(window + offset_of(name)));
}

/* Field `field` of register `name` in the window set to `value`, by the table's field. */
static void
set_field(const char *name, const char *field, uint32_t value)
{
	const erx_device_register_t *const r = &xhci->registers[erx_device_register_named(xhci, name)];
	const uint32_t at = erx_device_field_named(xhci, r, field);
	const erx_device_field_t *f;

	CHECK(at < r->field_count);
	f = &xhci->fields[r->first_field + at];
	*reg(name) = (uint32_t)((*reg(name) & ~f->mask) | ((uint64_t)value << f->shift));
}

/* Field `field` of register `name` in the window, by the table's field. */
static uint32_t
get_field(const char *name, const char *field)
{
	const erx_device_register_t *const r = &xhci->registers[erx_device_register_named(xhci, name)];
	const uint32_t at = erx_device_field_named(xhci, r, field);
	const erx_device_field_t *f;

	CHECK(at < r->field_count);
	f = &xhci->fields[r->first_field + at];
	return ((uint32_t)((*reg(name) & f->mask) >> f->shift));
}

/* A controller left running by firmware, reporting its clusters, `scratchpads` pages, 4 KiB pages if `four_kib`, and AC64 if `ac64`. */
static void
preset(uint32_t scratchpads, bool four_kib, bool ac64)
{
	bzero(window, WINDOW_BYTES);
	window[0] = OPERATIONAL;
	set_field("hcsparams1", "maxslots", 8);
	set_field("hcsparams1", "maxports", 4);
	set_field("hcsparams1", "maxintrs", 1);
	set_field("hcsparams2", "spb_max_lo", scratchpads & 31u);
	set_field("hcsparams2", "spb_max_hi", scratchpads >> 5);
	set_field("hccparams1", "ac64", ac64);
	*reg("dboff") = DOORBELLS;
	*reg("rtsoff") = RUNTIME;
	set_field("pagesize", "four_kib", four_kib);
	set_field("usbcmd", "rs", 1);
	set_field("usbcmd", "inte", 1);
	/* An interrupt pending from before the reset, which the install's IMAN.IE must not clear. */
	set_field("iman", "ip", 1);
}

static const erx_device_t *
open_xhci(uint32_t scratchpads, bool four_kib, bool ac64)
{
	const uint64_t window_object = make_memory(WINDOW_BYTES);
	const uint64_t memory = make_memory(DEVICE_MEMORY);
	const erx_device_spec_t spec = { .peripheral = "xhci", .peripheral_length = 4, .form = ERX_DEVICE_FORM_GIVEN,
	    .window = window_object, .base = 0, .size = WINDOW_BYTES, .memory = memory,
	    .memory_size = memory_sizes[memory] };
	uint32_t device;

	window = memories[window_object];
	preset(scratchpads, four_kib, ac64);
	maps[0] = window_object;
	maps[1] = memory;
	maps_pushed = 2;
	maps_done = 0;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_OK && maps_done == 2);
	return (erx_device_get(device));
}

/* One negotiate call, its answer and the stores it made. */
static int
negotiate(const erx_device_t *device, uint32_t expected_writes)
{
	uint64_t accepted = 1;
	int status;

	writes = 0;
	status = erx_device_negotiate(device, UINT64_MAX, &accepted);
	CHECK(writes == expected_writes);
	CHECK(status != ERX_OK || accepted == 0);
	return (status);
}

/* The bytes of the device's memory at device address `addr`, which must lie in it. */
static uint8_t *
memory_at(uint64_t addr, uint64_t length)
{
	const uint64_t mem = (addr >> SLOT_SHIFT) - 1;

	CHECK(!high_addresses && mem < memory_count && (addr & ((UINT64_C(1) << SLOT_SHIFT) - 1)) + length <= memory_sizes[mem]);
	return (memories[mem] + (addr & ((UINT64_C(1) << SLOT_SHIFT) - 1)));
}

static uint64_t
word64(const uint8_t *at)
{
	uint64_t value;

	memcpy(&value, at, sizeof(value));
	return (value);
}

/* The install's stores, in FreeBSD's order (xhci.c:329-428), each checked by the generated accessors. */
static void
check_install(void)
{
	static const char *const order[] = { "config", "dcbaap_lo", "dcbaap_hi", "erstsz", "erdp_lo", "erdp_hi",
	    "erstba_lo", "erstba_hi", "iman", "crcr_lo", "crcr_hi", "usbcmd" };
	uint64_t dcbaa, segment_table, dequeue, ring;

	for (uint32_t at = 0; at < sizeof(order) / sizeof(order[0]); at++)
		CHECK(write_offsets[at] == offset_of(order[at]));
	CHECK(erx_xhci_config_maxslotsen_get(*reg("config")) == 8);
	CHECK(erx_xhci_erstsz_size_get(*reg("erstsz")) == 1);
	CHECK(erx_xhci_iman_ie_get(*reg("iman")) == 1 && erx_xhci_iman_ip_get(*reg("iman")) == 0);
	CHECK(erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 1 && erx_xhci_usbcmd_inte_get(*reg("usbcmd")) == 1 &&
	    erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 0);
	CHECK(get_field("erdp_lo", "ehb") == 0 && get_field("erdp_lo", "desi") == 0);
	/* Each address whole across its two registers, and what the install wrote where it points. */
	dcbaa = (uint64_t)*reg("dcbaap_hi") << 32 | *reg("dcbaap_lo");
	segment_table = (uint64_t)*reg("erstba_hi") << 32 | *reg("erstba_lo");
	dequeue = (uint64_t)*reg("erdp_hi") << 32 | *reg("erdp_lo");
	ring = (uint64_t)*reg("crcr_hi") << 32 | (uint64_t)get_field("crcr_lo", "pointer_lo") << 6;
	CHECK(dcbaa % 64 == 0 && segment_table % 64 == 0 && dequeue % 16 == 0 && ring % 64 == 0);
	CHECK(get_field("crcr_lo", "rcs") == 1 && get_field("crcr_lo", "cs") == 0 && get_field("crcr_lo", "ca") == 0);
	CHECK(word64(memory_at(segment_table, 16)) == dequeue);
	CHECK(word64(memory_at(dcbaa, 8)) != 0 && word64(memory_at(word64(memory_at(dcbaa, 8)), 8)) != 0);
	(void)memory_at(ring, 16);
}

/* The start, one step a call, over a controller that answers each step only after the harness lets it. */
static void
test_start(void)
{
	const erx_device_t *const device = open_xhci(2, true, true);
	uint32_t queue;

	CHECK(erx_device_queue_create(device, 0, 8, 4096, &queue) == ERX_ENOTSUP);
	CHECK(negotiate(device, 1) == ERX_EBUSY && write_offsets[0] == offset_of("usbcmd"));
	CHECK(erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0 && erx_xhci_usbcmd_inte_get(*reg("usbcmd")) == 1);
	CHECK(negotiate(device, 0) == ERX_EBUSY);	/* not halted yet */
	set_field("usbsts", "hch", 1);
	CHECK(negotiate(device, 1) == ERX_EBUSY && erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 1);
	set_field("usbsts", "cnr", 1);
	CHECK(negotiate(device, 0) == ERX_EBUSY);	/* HCRST still set */
	set_field("usbcmd", "hcrst", 0);
	set_field("usbcmd", "inte", 0);			/* a reset closes INTE (5.4.1, p. 394) */
	CHECK(negotiate(device, 0) == ERX_EBUSY);	/* CNR still set */
	set_field("usbsts", "cnr", 0);
	CHECK(negotiate(device, 12) == ERX_EBUSY);
	check_install();
	CHECK(negotiate(device, 0) == ERX_EBUSY);	/* still halted */
	set_field("usbsts", "hch", 0);
	CHECK(negotiate(device, 0) == ERX_OK);
	/* A started controller's next negotiation begins again with run cleared. */
	CHECK(negotiate(device, 1) == ERX_EBUSY && erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0);
}

/* What a negotiation refuses before it writes anything. */
static void
test_refusals(void)
{
	CHECK(negotiate(open_xhci(ERX_DEVICE_TRB_SCRATCHPADS_MAX + 1, true, true), 0) == ERX_ENOTSUP);
	CHECK(negotiate(open_xhci(2, false, true), 0) == ERX_ENOTSUP);
	high_addresses = true;
	CHECK(negotiate(open_xhci(2, true, false), 0) == ERX_ERANGE);
	high_addresses = false;
}

int
main(void)
{
	xhci = erx_device_peripheral_find("xhci", 4);
	CHECK(xhci != NULL);
	test_refusals();
	test_start();
	printf("erx_device_xhci done\n");
	return (0);
}
