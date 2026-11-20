/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The records and the register accesses. See erx_device.h.
 */

#include "erx_device.h"

#include <stdatomic.h>
#ifdef ERX_DEVICE_STAND_IN
#include <stdlib.h>
#include <string.h>
#endif

#include "erx/hw/device_access.h"
#include "erx/hw/device_owned.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/mem.h"

#include "erx_device_dma.h"
#include "erx_device_genet.h"
#include "erx_device_genet_model.h"
#include "erx_device_virtio_core.h"
#include "erx_dma_arch.h"

/* The rings are virtio's little-endian layouts, written and read through their own types. */
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "erx_device writes virtio rings in the CPU's byte order, which must be little-endian"
#endif

/* The SVD profile has one address block per peripheral, and the table a window for each register. */
#define ERX_DEVICE_WINDOWS_MAX	1u

struct erx_device {
	const erx_device_peripheral_t	*peripheral;
	volatile uint8_t		*windows[ERX_DEVICE_WINDOWS_MAX];
	erx_device_form_t		form;
	uint64_t			window;		/* a given device's window object */
	uint64_t			base;
	uint64_t			size;
	uint32_t			line_count;
	uint64_t			lines[ERX_DEVICE_LINES_MAX];	/* as the spec named them */
	uint32_t			entries[ERX_DEVICE_LINES_MAX];	/* each line's in line_entries */
	uint64_t			memory;		/* a given device's memory object */
	uint64_t			memory_size;	/* its bytes, 0 for none */
	uint8_t				*dma;		/* this domain's mapping of it */
	bool				coherent;	/* its DMA is cache-coherent */
	uintptr_t			register_keys[ERX_DEVICE_REGISTERS_MAX];
	uintptr_t			field_keys[ERX_DEVICE_FIELDS_MAX];
	erx_device_layout_t		layout;		/* where its registers are, decided at open */
};

static erx_device_t devices[ERX_DEVICE_MAX];
static _Atomic uint32_t devices_open;

/*
 * What records share (docs/design-shared-devices.md, "Pages inside a domain" and "Lines
 * inside a domain"). A run is the pages a record's window covers, mapped once at the first
 * open of any record in it; a line entry is one IRQ object, which a given record names by
 * the object's handle and any other by its selector, with the records' mark of whether two
 * devices of the unit name it. Both are kept for the boot, as records are, so an open that
 * fails after making one leaves it for the next open to take. Only opens, which the caller
 * serialises, write them, and nothing reads them through a record before the record is
 * published in devices_open.
 */
typedef struct page_run {
	erx_device_form_t	form;
	uint64_t		window;		/* a given run's window object */
	erx_device_pages_t	pages;		/* `offset` is 0 */
	volatile uint8_t	*mapping;	/* its first page */
} page_run_t;

typedef struct line_entry {
	erx_device_form_t	form;		/* whose naming `key` is */
	uint64_t		key;		/* a given record's handle, or a selector */
	uint64_t		irq;
	bool			shared;
} line_entry_t;

static page_run_t runs[ERX_DEVICE_MAX];
static uint32_t runs_mapped;
static line_entry_t line_entries[ERX_DEVICE_LINE_ENTRIES_MAX];
static uint32_t lines_taken;

#ifdef ERX_DEVICE_STAND_IN
/* The stand-in's device model, defined below store(), which calls it. */
static void	stand_in_preset(const erx_device_t *device);
static void	stand_in_stored(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset,
	    uint64_t value);
#endif

/*
 * `size` bytes of the object from `offset`, mapped read and write where the kernel reserves
 * room; a map the kernel refuses gives the reservation back.
 */
static int
map_object(uint64_t mem, uint64_t offset, uint64_t size, uint64_t *addr)
{
	int status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr);

	if (status == ERX_OK) {
		status = erx_vm_map(ERX_CAP_SELF, *addr, size, mem, offset, ERX_PROT_RW);
		if (status != ERX_OK)
			(void)erx_vm_release(ERX_CAP_SELF, *addr, size);
	}
	return (status);
}

/* A hosted stand-in's window, `size` bytes of plain memory; no other build has one. */
static int
stand_in_window(uint64_t size, volatile uint8_t **window)
{
#ifdef ERX_DEVICE_STAND_IN
	*window = calloc(1, size);
	return (*window != NULL ? ERX_OK : ERX_ENOMEM);
#else
	(void)size;
	(void)window;
	return (ERX_ENOTSUP);
#endif
}

/*
 * A run's mapping: its pages, a physical device's an object made here from their addresses
 * and a given device's the pages of its window object at their offsets in it.
 */
static int
map_run(const erx_device_spec_t *spec, const erx_device_pages_t *pages, volatile uint8_t **mapping)
{
	uint64_t mem = spec->window, offset = pages->base, addr;
	int status = ERX_OK;

	if (spec->form == ERX_DEVICE_FORM_PHYSICAL) {
		status = erx_mem_create_physical(0, 0, pages->base, pages->size, ERX_MEM_ATTR_DEVICE, &mem);
		offset = 0;
	}
	if (status == ERX_OK)
		status = map_object(mem, offset, pages->size, &addr);
	if (status == ERX_OK)
		*mapping = (volatile uint8_t *)(uintptr_t)addr;
	return (status);
}

/*
 * Whether the window's pages are a mapped run's, with the run; ERX_EBUSY when they meet a
 * run without being it, since a run is its unit's pages and the record's writer and the unit
 * then disagree.
 */
static int
find_run(const erx_device_spec_t *spec, const erx_device_pages_t *pages, bool *found, uint32_t *run)
{
	*found = false;
	for (uint32_t index = 0; index < runs_mapped; index++) {
		const page_run_t *const mapped = &runs[index];

		if (mapped->form != spec->form || mapped->window != spec->window ||
		    !erx_device_pages_overlap(&mapped->pages, pages))
			continue;
		if (mapped->pages.base != pages->base || mapped->pages.size != pages->size)
			return (ERX_EBUSY);
		*found = true;
		*run = index;
		return (ERX_OK);
	}
	return (ERX_OK);
}

/*
 * The window inside its run's mapping, the run mapped here when this is the first open in
 * it. A hosted stand-in's window is plain memory of its own.
 */
static int
take_window(const erx_device_spec_t *spec, const erx_device_pages_t *pages, uint64_t size, volatile uint8_t **window)
{
	page_run_t *run;
	uint32_t index = runs_mapped;
	bool found;
	int status;

	if (spec->form == ERX_DEVICE_FORM_STAND_IN)
		return (stand_in_window(size, window));
	status = find_run(spec, pages, &found, &index);
	if (status != ERX_OK)
		return (status);
	if (!found && runs_mapped == ERX_DEVICE_MAX)
		return (ERX_ELIMIT);
	run = &runs[index];
	if (!found) {
		status = map_run(spec, pages, &run->mapping);
		if (status != ERX_OK)
			return (status);
		run->form = spec->form;
		run->window = spec->window;
		run->pages = (erx_device_pages_t){ .base = pages->base, .size = pages->size };
		runs_mapped++;
	}
	/* A run is its record's pages, so the window starts at its offset in the run's first page. */
	*window = run->mapping + pages->offset;
	return (ERX_OK);
}

/* The entry of the spec's line, false for a line no open has taken. */
static bool
find_line(const erx_device_spec_t *spec, uint32_t line, uint32_t *entry)
{
	for (uint32_t index = 0; index < lines_taken; index++) {
		if (line_entries[index].form == spec->form && line_entries[index].key == spec->lines[line]) {
			*entry = index;
			return (true);
		}
	}
	return (false);
}

/* Whether one of the first `open` records names the line entry. */
static bool
line_named(uint32_t entry, uint32_t open)
{
	for (uint32_t index = 0; index < open; index++) {
		for (uint32_t line = 0; line < devices[index].line_count; line++) {
			if (devices[index].entries[line] == entry)
				return (true);
		}
	}
	return (false);
}

/*
 * Whether the spec's lines agree with what is taken: a line two records name is shared, so
 * a spec that marks a taken line otherwise than its entry, or names a direct line an open
 * record names, disagrees with the unit. Checked before anything is made.
 */
static bool
lines_agree(const erx_device_spec_t *spec, uint32_t open)
{
	uint32_t entry;

	for (uint32_t line = 0; line < spec->line_count; line++) {
		if (find_line(spec, line, &entry) && (line_entries[entry].shared != spec->shared[line] ||
		    (!spec->shared[line] && line_named(entry, open))))
			return (false);
	}
	return (true);
}

/*
 * Each line's entry: the one taken already, or a new one holding the line's IRQ object, a
 * given device's as it was given it and any other's made from its selector.
 */
static int
take_lines(const erx_device_spec_t *spec, uint32_t *entries)
{
	const uint32_t kind = spec->form == ERX_DEVICE_FORM_STAND_IN ? ERX_IRQ_SOFT : ERX_IRQ_LINE;
	line_entry_t *entry;
	int status = ERX_OK;

	for (uint32_t line = 0; status == ERX_OK && line < spec->line_count; line++) {
		if (find_line(spec, line, &entries[line]))
			continue;
		if (lines_taken == ERX_DEVICE_LINE_ENTRIES_MAX)
			return (ERX_ELIMIT);
		entry = &line_entries[lines_taken];
		*entry = (line_entry_t){ .form = spec->form, .key = spec->lines[line], .irq = spec->lines[line],
		    .shared = spec->shared[line] };
		if (spec->form != ERX_DEVICE_FORM_GIVEN)
			status = erx_irq_create(0, 0, kind, spec->lines[line], &entry->irq, NULL);
		if (status == ERX_OK)
			entries[line] = lines_taken++;
	}
	return (status);
}

/* A given device's memory, mapped here whole, or nothing for a device with none. */
static int
map_memory(const erx_device_spec_t *spec, uint8_t **dma)
{
	uint64_t addr;
	int status;

	*dma = NULL;
	if (spec->memory_size == 0)
		return (ERX_OK);
	status = map_object(spec->memory, 0, spec->memory_size, &addr);
	if (status == ERX_OK)
		*dma = (uint8_t *)(uintptr_t)addr;
	return (status);
}

/* Whether the spec names each of its lines once. */
static bool
lines_distinct(const erx_device_spec_t *spec)
{
	for (uint32_t line = 0; line < spec->line_count && line < ERX_DEVICE_LINES_MAX; line++) {
		for (uint32_t other = line + 1; other < spec->line_count && other < ERX_DEVICE_LINES_MAX; other++) {
			if (spec->lines[line] == spec->lines[other])
				return (false);
		}
	}
	return (true);
}

/*
 * Every part of the spec the table or the record bounds, checked before anything is made,
 * and the pages a window's mapping covers. A stand-in has none. Memory is a given device's
 * alone, and whole pages.
 */
static bool
spec_fits(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral, erx_device_pages_t *pages)
{
	*pages = (erx_device_pages_t){ 0 };
	if (peripheral == NULL || spec->line_count > ERX_DEVICE_LINES_MAX || !lines_distinct(spec) ||
	    (spec->form != ERX_DEVICE_FORM_GIVEN && spec->memory_size != 0) || (spec->memory_size & (ERX_PAGE_SIZE - 1)) != 0)
		return (false);
	return (spec->form == ERX_DEVICE_FORM_STAND_IN ||
	    (spec->size >= peripheral->window_size && erx_device_base_aligned(peripheral, spec->base) &&
	    erx_device_window_pages(spec->base, spec->size, pages)));
}

/* Whether a record's window and the spec's are in one space: physical memory, or one window object. */
static bool
same_space(const erx_device_t *record, const erx_device_spec_t *spec)
{
	return (record->form == spec->form && record->window == spec->window);
}

static bool
same_spec(const erx_device_t *record, const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral)
{
	if (record->peripheral != peripheral || record->size != spec->size || record->line_count != spec->line_count ||
	    record->memory != spec->memory || record->memory_size != spec->memory_size || record->coherent != spec->coherent)
		return (false);
	for (uint32_t line = 0; line < spec->line_count; line++) {
		if (record->lines[line] != spec->lines[line] ||
		    line_entries[record->entries[line]].shared != spec->shared[line])
			return (false);
	}
	return (true);
}

/*
 * Whether an earlier open decides this one, and what it decides. The same window is that
 * device again, or refused if anything else differs. So is memory another record holds,
 * since each device's queues are carved from its own, and a window that overlaps another
 * record's, whose registers would then reach the other's. Another window in the same pages is
 * a new record, which find_run places in their run. A stand-in has no window to share, so it is
 * always a new device.
 */
static bool
find_open(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral, uint32_t open, uint32_t *device,
    int *status)
{
	for (uint32_t index = 0; index < open && spec->form != ERX_DEVICE_FORM_STAND_IN; index++) {
		const erx_device_t *const record = &devices[index];

		if (record->form == ERX_DEVICE_FORM_STAND_IN)
			continue;
		if (same_space(record, spec) && record->base == spec->base) {
			*device = index;
			*status = same_spec(record, spec, peripheral) ? ERX_OK : ERX_EBUSY;
			return (true);
		}
		if ((same_space(record, spec) && record->base < spec->base + spec->size && spec->base < record->base + record->size) ||
		    (spec->memory_size != 0 && record->memory_size != 0 && record->memory == spec->memory)) {
			*status = ERX_EBUSY;
			return (true);
		}
	}
	return (false);
}

/* One volatile load of `width` bits at `offset` of a window, which the table holds as 8, 16, 32 or 64. */
static uint64_t
load_word(volatile uint8_t *window, uint8_t width, uint64_t offset)
{
	switch (width) {
	case 8:
		return (erx_device_access_load8(window, offset));
	case 16:
		return (erx_device_access_load16(window, offset));
	case 64:
		return (erx_device_access_load64(window, offset));
	default:
		return (erx_device_access_load32(window, offset));
	}
}

/*
 * The record's layout, erx_device_resolve run over its window of `size` bytes: each read it
 * asks for is one load, and it asks for no more than its sources and ERX_DEVICE_LIST_ENTRIES_MAX
 * list entries, each inside the window.
 */
static bool
resolve_layout(erx_device_t *record, uint64_t size)
{
	erx_device_resolve_t resolve;

	erx_device_resolve_begin(record->peripheral, size, &record->layout, &resolve);
	while (resolve.op == ERX_DEVICE_RESOLVE_READ)
		erx_device_resolve_step(record->peripheral, &record->layout, &resolve,
		    load_word(record->windows[0], resolve.width, resolve.offset));
	return (resolve.op == ERX_DEVICE_RESOLVE_DONE);
}

int
erx_device_open(const erx_device_spec_t *spec, const uintptr_t *register_keys, const uintptr_t *field_keys,
    uint32_t *device)
{
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral_find(spec->peripheral, spec->peripheral_length);
	const uint32_t open = atomic_load_explicit(&devices_open, memory_order_relaxed);
	erx_device_pages_t pages;
	erx_device_t *record;
	int status;

	if (!spec_fits(spec, peripheral, &pages))
		return (ERX_EINVAL);
	if (find_open(spec, peripheral, open, device, &status))
		return (status);
	if (open == ERX_DEVICE_MAX)
		return (ERX_ELIMIT);
	if (!lines_agree(spec, open))
		return (ERX_EBUSY);
	record = &devices[open];
	record->peripheral = peripheral;
	status = take_window(spec, &pages, peripheral->window_size, &record->windows[0]);
	/* A stand-in's window is the table's size; any other's the spec's, which spec_fits held to at least that. */
	if (status == ERX_OK &&
	    !resolve_layout(record, spec->form == ERX_DEVICE_FORM_STAND_IN ? peripheral->window_size : spec->size))
		status = ERX_EINVAL;
	if (status == ERX_OK)
		status = take_lines(spec, record->entries);
	if (status == ERX_OK)
		status = map_memory(spec, &record->dma);
	if (status != ERX_OK)
		return (status);
	record->form = spec->form;
	record->window = spec->window;
	record->base = spec->base;
	record->size = spec->size;
	record->line_count = spec->line_count;
	for (uint32_t line = 0; line < spec->line_count; line++)
		record->lines[line] = spec->lines[line];
	record->memory = spec->memory;
	record->memory_size = spec->memory_size;
	record->coherent = spec->coherent;
	for (uint32_t index = 0; register_keys != NULL && index < peripheral->register_count; index++)
		record->register_keys[index] = register_keys[index];
	for (uint32_t index = 0; field_keys != NULL && index < peripheral->field_count; index++)
		record->field_keys[index] = field_keys[index];
#ifdef ERX_DEVICE_STAND_IN
	if (record->form == ERX_DEVICE_FORM_STAND_IN)
		stand_in_preset(record);
#endif
	atomic_store_explicit(&devices_open, open + 1, memory_order_release);
	*device = open;
	return (ERX_OK);
}

const erx_device_t *
erx_device_get(uint64_t device)
{
	return (device < atomic_load_explicit(&devices_open, memory_order_acquire) ? &devices[device] : NULL);
}

const erx_device_peripheral_t *
erx_device_peripheral(const erx_device_t *device)
{
	return (device->peripheral);
}

const erx_device_register_t *
erx_device_register_by_key(const erx_device_t *device, uintptr_t key)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_key_find(device->register_keys, peripheral->register_count, key);

	return (found == peripheral->register_count ? NULL : &peripheral->registers[found]);
}

const erx_device_field_t *
erx_device_field_by_key(const erx_device_t *device, const erx_device_register_t *reg, uintptr_t key)
{
	const uint32_t found = erx_device_key_find(&device->field_keys[reg->first_field], reg->field_count, key);

	return (found == reg->field_count ? NULL : &device->peripheral->fields[reg->first_field + found]);
}

/* The one load of a register: one access of its declared width. */
static uint64_t
load(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset)
{
	return (load_word(device->windows[reg->window], reg->width, offset));
}

/* One volatile store of the register's declared width at `offset` of its window. */
static void
store_width(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	volatile uint8_t *const window = device->windows[reg->window];

	switch (reg->width) {
	case 8:
		erx_device_access_store8(window, offset, (uint8_t)value);
		break;
	case 16:
		erx_device_access_store16(window, offset, (uint16_t)value);
		break;
	case 64:
		erx_device_access_store64(window, offset, value);
		break;
	default:
		erx_device_access_store32(window, offset, (uint32_t)value);
		break;
	}
}

/*
 * The one store to a register, waited for before anything after it: a store the device
 * answers with a bus error raises it asynchronously (an SError on AArch64), and the wait
 * has the answer arrive before the call returns, so the error is pending by then; the
 * architecture does not bound when it is taken, so that its pc lies in the store's
 * caller is likely, not certain. A hosted stand-in's device then acts on the store, as
 * a device would.
 */
static void
store(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	store_width(device, reg, offset, value);
	erx_dma_store_wait();
#ifdef ERX_DEVICE_STAND_IN
	if (device->form == ERX_DEVICE_FORM_STAND_IN)
		stand_in_stored(device, reg, offset, value);
#endif
}

#ifdef ERX_DEVICE_STAND_IN
/*
 * The hosted stand-in's model of a virtio-mmio transport, over its plain memory: the device
 * side of the few registers whose value is not simply what was last stored. It is a version 2
 * device whose queues take the largest size, offering VERSION_1 alone, and a reset lets every
 * queue go, as section 4.2.2.1 of the virtio specification has it. Its one ready word serves
 * every queue selector, so it models a device that holds all its queues ready or none. A
 * stand-in GENET is erx_device_genet_model over its window. A stand-in of another
 * peripheral is plain memory only.
 */
static bool
stand_in_virtio(const erx_device_t *device)
{
	return (erx_device_peripheral_is(device->peripheral, "virtio_mmio"));
}

/*
 * A register of the stand-in's memory, set at its width as its device would set it: straight to the
 * memory, not through store(), so the model never acts on its own stores. A name the table
 * does not have sets nothing.
 */
static void
stand_in_set(const erx_device_t *device, const char *name, uint32_t value)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_register_named(peripheral, name);

	if (found < peripheral->register_count)
		store_width(device, &peripheral->registers[found], peripheral->registers[found].offset, value);
}

static bool
stand_in_genet(const erx_device_t *device)
{
	return (device->peripheral == erx_device_peripheral_find("genet", sizeof("genet") - 1));
}

/* A field of a register of the device's table by its name, or NULL. */
static const erx_device_field_t *
stand_in_field(const erx_device_t *device, const erx_device_register_t *reg, const char *name)
{
	const uint32_t found = erx_device_field_named(device->peripheral, reg, name);

	return (found < reg->field_count ? &device->peripheral->fields[reg->first_field + found] : NULL);
}

/*
 * The stand-in GENET's controller: erx_device_genet_model over its window, built for each
 * call. It keeps nothing between calls, since its stop shows at the store that makes it
 * (no DMA status reads), so all it knows is in the window and the queues' memory.
 */
static bool
stand_in_genet_model(const erx_device_t *device, erx_device_genet_model_t *model)
{
	return (stand_in_genet(device) && erx_device_genet_model_init(model, device->peripheral, device->windows[0], 0));
}

/* What a stand-in's virtio transport, or its GENET's revision, reads as before the driver stores anything. */
static void
stand_in_preset(const erx_device_t *device)
{
	erx_device_genet_model_t genet;

	if (stand_in_genet_model(device, &genet))
		erx_device_genet_model_preset(&genet);
	if (!stand_in_virtio(device))
		return;
	stand_in_set(device, "magic", ERX_VIRTIO_MMIO_MAGIC);
	stand_in_set(device, "version", ERX_VIRTIO_MMIO_VERSION);
	stand_in_set(device, "queue_num_max", ERX_DEVICE_QUEUE_SIZE_MAX);
}

/*
 * The device's side of the store of `value` at `offset` in `reg`: GENET's model acts on it,
 * and a virtio transport sets the features word the selector names or resets.
 */
static void
stand_in_stored(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	const erx_device_register_t *const owned = device->peripheral->registers;
	const uint32_t version_word = ERX_VIRTIO_F_VERSION_1 / 32, version_bit = ERX_VIRTIO_F_VERSION_1 % 32;
	erx_device_genet_model_t genet;

	if (stand_in_genet_model(device, &genet)) {
		erx_device_genet_model_stored(&genet, (uint32_t)offset, (uint32_t)value);
		return;
	}
	if (!stand_in_virtio(device))
		return;
	if (reg == &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DEVICE_FEATURES_SEL])
		stand_in_set(device, "device_features", value == version_word ? UINT32_C(1) << version_bit : 0);
	if (reg == &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_STATUS] && value == 0)
		stand_in_set(device, "queue_ready", 0);
}
#endif

/* Where the element is in the device's window, by the layout its open decided; false for an element it does not have. */
static bool
element_at(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t *offset)
{
	return (erx_device_layout_offset(device->peripheral, &device->layout, reg, element.indexed, element.index, offset));
}

bool
erx_device_read(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t *value)
{
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || !erx_device_read_allowed(reg))
		return (false);
	*value = load(device, reg, offset);
	return (true);
}

/*
 * A write of a register with fields the NIF owns reads it first, which the generator allows
 * only where the read has no side effect, and is refused when it would change one of them.
 */
bool
erx_device_write(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t value)
{
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || !erx_device_write_allowed(reg, value) ||
	    (reg->owned != 0 && !erx_device_owned_kept(reg, load(device, reg, offset), value)))
		return (false);
	store(device, reg, offset, value);
	return (true);
}

uint32_t
erx_device_elements(const erx_device_t *device, const erx_device_register_t *reg)
{
	return (device->layout.elements[reg - device->peripheral->registers]);
}

/*
 * The command register and its DMA enable are found by their table names in sdhci's
 * table, so only a device of that peripheral reaches the register and the bit is the SVD
 * source's; a table that does not mark the register owned is refused whole.
 */
bool
erx_device_command(const erx_device_t *device, uint64_t word)
{
	const erx_device_peripheral_t *const sdhci = erx_device_peripheral_find("sdhci", sizeof("sdhci") - 1);
	const erx_device_register_t *cmdtm;
	uint32_t found, dma;

	if (sdhci == NULL || device->peripheral != sdhci)
		return (false);
	found = erx_device_register_named(sdhci, "cmdtm");
	if (found == sdhci->register_count || !sdhci->registers[found].owned_by_nif)
		return (false);
	cmdtm = &sdhci->registers[found];
	dma = erx_device_field_named(sdhci, cmdtm, "trns_dma");
	if (dma == cmdtm->field_count || !erx_device_command_allowed(cmdtm, &sdhci->fields[cmdtm->first_field + dma], word))
		return (false);
	store(device, cmdtm, cmdtm->offset, word);
	return (true);
}

bool
erx_device_read_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
    const erx_device_field_t *field, uint64_t *value)
{
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || !erx_device_field_read_allowed(reg, field))
		return (false);
	*value = erx_device_field_get(field, load(device, reg, offset));
	return (true);
}

bool
erx_device_field_of(const erx_device_register_t *reg, erx_device_element_t element, const erx_device_field_t *field,
    uint64_t word, uint64_t *value)
{
	uint64_t offset;

	if (!erx_device_element_offset(reg, element.indexed, element.index, &offset) ||
	    !erx_device_field_read_allowed(reg, field) || !erx_device_word_fits(reg, word))
		return (false);
	*value = erx_device_field_get(field, word);
	return (true);
}

bool
erx_device_write_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
    const erx_device_field_t *field, uint64_t value)
{
	const erx_device_field_plan_t plan = erx_device_field_plan(reg, field, value);
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || plan.op == ERX_DEVICE_FIELD_REFUSED)
		return (false);
	store(device, reg, offset, erx_device_field_apply(&plan, plan.op == ERX_DEVICE_FIELD_UPDATE ? load(device, reg, offset) : 0));
	return (true);
}

bool
erx_device_line_irq(const erx_device_t *device, uint64_t line, uint64_t *irq)
{
	if (line >= device->line_count)
		return (false);
	*irq = line_entries[device->entries[line]].irq;
	return (true);
}

bool
erx_device_line_entry(const erx_device_t *device, uint64_t line, uint32_t *entry)
{
	if (line >= device->line_count)
		return (false);
	*entry = device->entries[line];
	return (true);
}

erx_device_bind_t
erx_device_bind_check(const erx_device_t *device, uint64_t line, erx_device_binder_t binder, const erx_device_t *through,
    uint64_t through_line)
{
	if (line >= device->line_count)
		return (ERX_DEVICE_BIND_NO_LINE);

	const bool shared = line_entries[device->entries[line]].shared;

	if (shared && binder == ERX_DEVICE_BINDER_DRIVER)
		return (ERX_DEVICE_BIND_SHARED);
	if (!shared && binder == ERX_DEVICE_BINDER_OWNER)
		return (ERX_DEVICE_BIND_DIRECT);
	if (through != NULL && (through != device || through_line != line))
		return (ERX_DEVICE_BIND_BUSY);
	return (ERX_DEVICE_BIND_OK);
}

/*
 * The queues and the device's initialisation. Each queue record is written whole by
 * erx_device_queue_create and changes only under the caller's serialisation. `ready` is true
 * from the install at the end of a negotiation to the start of the next: a queue that is not
 * ready is one the device may have forgotten, so nothing is posted on it and nothing
 * completed from it.
 *
 * A record runs one of the descriptor forms (docs/design-device-dma.md, "The descriptor
 * forms"), which the device's peripheral fixes: virtio-mmio's split ring, whose rings lie in
 * the queue's memory before its pool, or GENET's register ring, whose descriptors are the
 * device's registers, so its queue's memory is its pool alone. Everything the effect layer
 * does is common to both; only the form's core and the registers its plans publish differ.
 */
typedef struct virtio_registers {
	/* What the NIF reads and the driver may read too. */
	const erx_device_register_t	*version;
	const erx_device_register_t	*device_features;
	const erx_device_register_t	*num_max;
	/* The registers the NIF owns (erx/hw/device_owned.h), which only this file writes. */
	const erx_device_register_t	*status;
	const erx_device_register_t	*device_features_sel;
	const erx_device_register_t	*driver_features;
	const erx_device_register_t	*driver_features_sel;
	const erx_device_register_t	*sel;
	const erx_device_register_t	*num;
	const erx_device_register_t	*ready;
	const erx_device_register_t	*notify;
	/* The rings' device addresses, low word then high word: written only by the install's plan. */
	const erx_device_register_t	*desc[2];
	const erx_device_register_t	*driver[2];
	const erx_device_register_t	*device[2];
	/* The status register's bits, from its fields in the table. */
	uint64_t			acknowledge;
	uint64_t			driver_bit;
	uint64_t			features_ok;
	uint64_t			driver_ok;
	uint64_t			failed;
} virtio_registers_t;

/* A GENET record's queues: receive, then transmit, in virtio-net's order. */
#define GENET_QUEUE_RX	0u
#define GENET_QUEUE_TX	1u

typedef enum queue_form {
	QUEUE_SPLIT_RING,		/* virtio-mmio */
	QUEUE_REGISTER_RING,		/* GENET */
} queue_form_t;

/* A split ring: its device's virtio-mmio registers and the form's core, which owns its layout. */
typedef struct split_ring {
	virtio_registers_t		regs;
	erx_split_ring_t		ring;
} split_ring_t;

typedef struct register_ring {
	erx_device_genet_registers_t	regs;		/* the direction's, which the context's owned list points into */
	erx_dma_length_reg_t		length_reg;	/* the ring's buffer size, which the context names as a length */
	erx_device_genet_queue_t	core;
} register_ring_t;

typedef struct queue_record {
	const erx_device_t		*device;
	uint32_t			index;		/* the device's own number for the queue */
	queue_form_t			form;
	bool				ready;
	volatile uint8_t		*memory;	/* this domain's mapping of the queue: its rings, if any, from 0 */
	uint64_t			memory_size;	/* the rings, any gap, then the pool */
	uint64_t			pool_offset;	/* the pool's first byte, a granule boundary past the rings */
	uint64_t			device_base;	/* the device address of the queue's first byte */
	erx_dma_context_t		context;	/* the check's facts, from the fields above and the form */
	erx_dma_state_t			state;		/* who writes each region, as the last plan run left it */
	union {
		split_ring_t		split;		/* QUEUE_SPLIT_RING */
		register_ring_t		genet;		/* QUEUE_REGISTER_RING */
	};
} queue_record_t;

static queue_record_t queues[ERX_DEVICE_QUEUES_MAX];
static uint32_t queues_open;
/* The bytes of each given device's memory its queues and regions have taken, from the start, by the device's index. */
static uint64_t memory_taken[ERX_DEVICE_MAX];
/*
 * Each given device's region table, by the device's index: every region erx_device_region made
 * for it, which each of its split rings' ledgers reads (erx_dma_ledger_make), so a post names
 * only its own device's regions. Changed only under the caller's lock, as every queue call is.
 */
static erx_dma_regions_t device_regions[ERX_DEVICE_MAX];

/* The device's region table: the one place a device finds its own. */
static erx_dma_regions_t *
regions_of(const erx_device_t *device)
{
	return (&device_regions[device - devices]);
}

/* A plain register of the device's table by name, or NULL; only virtio's queue sequence names them. */
static const erx_device_register_t *
plain_register(const erx_device_t *device, const char *name)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_register_named(peripheral, name);

	return (found == peripheral->register_count || peripheral->registers[found].count != 1 ? NULL :
	    &peripheral->registers[found]);
}

/*
 * The register, or the element of an array, that begins at a window offset of the device's
 * table, for one access at that offset: its width and its window. NULL for an offset where no
 * register or element begins. Plans name registers by window offset, so this one lookup maps
 * every register step, owned or not, to the register the table puts there.
 */
static const erx_device_register_t *
register_at(const erx_device_peripheral_t *peripheral, uint32_t offset)
{
	for (uint32_t at = 0; at < peripheral->register_count; at++) {
		const erx_device_register_t *const reg = &peripheral->registers[at];
		const uint32_t past = offset - reg->offset;

		if (offset < reg->offset)
			continue;
		if (reg->count == 1 ? past == 0 : reg->stride != 0 && past % reg->stride == 0 && past / reg->stride < reg->count)
			return (reg);
	}
	return (NULL);
}

/* A plain register's one access, at its own offset. */
static uint64_t
get(const erx_device_t *device, const erx_device_register_t *reg)
{
	return (load(device, reg, reg->offset));
}

static void
put(const erx_device_t *device, const erx_device_register_t *reg, uint64_t value)
{
	store(device, reg, reg->offset, value);
}

/* A field's mask in the status register, by its table name, or 0 for none. */
static uint64_t
status_bit(const erx_device_peripheral_t *virtio, const erx_device_register_t *status, const char *name)
{
	const uint32_t found = erx_device_field_named(virtio, status, name);

	return (found == status->field_count ? 0 : virtio->fields[status->first_field + found].mask);
}

/*
 * The registers of a virtio-mmio device: those the NIF only reads by name, and those it owns
 * by their generated index in virtio_mmio's table. The device's peripheral is virtio_mmio or
 * a kind whose table begins with virtio_mmio's registers at the same indices
 * (docs/design-generation.md, "Register inputs"). False for any other peripheral.
 */
static bool
virtio_registers(const erx_device_t *device, virtio_registers_t *regs)
{
	const erx_device_peripheral_t *const virtio = device->peripheral;
	const erx_device_register_t *owned;

	if (!erx_device_peripheral_is(virtio, "virtio_mmio"))
		return (false);
	owned = virtio->registers;
	regs->version = plain_register(device, "version");
	regs->device_features = plain_register(device, "device_features");
	regs->num_max = plain_register(device, "queue_num_max");
	regs->status = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_STATUS];
	regs->device_features_sel = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DEVICE_FEATURES_SEL];
	regs->driver_features = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DRIVER_FEATURES];
	regs->driver_features_sel = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DRIVER_FEATURES_SEL];
	regs->sel = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_SEL];
	regs->num = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_NUM];
	regs->ready = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_READY];
	regs->notify = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_NOTIFY];
	regs->desc[0] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DESC_LOW];
	regs->desc[1] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DESC_HIGH];
	regs->driver[0] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DRIVER_LOW];
	regs->driver[1] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DRIVER_HIGH];
	regs->device[0] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DEVICE_LOW];
	regs->device[1] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DEVICE_HIGH];
	regs->acknowledge = status_bit(virtio, regs->status, "acknowledge");
	regs->driver_bit = status_bit(virtio, regs->status, "driver");
	regs->features_ok = status_bit(virtio, regs->status, "features_ok");
	regs->driver_ok = status_bit(virtio, regs->status, "driver_ok");
	regs->failed = status_bit(virtio, regs->status, "failed");
	return (regs->version != NULL && regs->device_features != NULL && regs->num_max != NULL &&
	    regs->acknowledge != 0 && regs->driver_bit != 0 && regs->features_ok != 0 && regs->driver_ok != 0 &&
	    regs->failed != 0);
}

/* Whether the device's queues are the register ring's: its peripheral is GENET's. */
static bool
register_ring_device(const erx_device_t *device)
{
	return (device->peripheral == erx_device_peripheral_find("genet", sizeof("genet") - 1));
}

/*
 * No queue's pool passes the largest contiguous object: the largest pool is the most buffers
 * of the largest size, a whole number of pages, which rounding to a granule of at most a page
 * leaves unchanged.
 */
_Static_assert((uint64_t)ERX_DEVICE_QUEUE_SIZE_MAX * ERX_DEVICE_BUFFER_MAX <= ERX_MEM_CONTIGUOUS_MAX &&
    (uint64_t)ERX_GENET_RING_SIZE * ERX_DEVICE_BUFFER_MAX <= ERX_MEM_CONTIGUOUS_MAX &&
    ERX_DEVICE_BUFFER_MAX % ERX_PAGE_SIZE == 0, "a queue's pool fits one contiguous object");
_Static_assert(ERX_GENET_RING_SIZE <= ERX_DMA_REGIONS_MAX, "a register ring's buffers fit a state");

/* `bytes` rounded up to a power of two `granule`; neither is near UINT32_MAX here. */
static uint32_t
granule_round(uint32_t bytes, uint32_t granule)
{
	return ((bytes + granule - 1) & ~(granule - 1));
}

/*
 * The bytes of a split ring's memory, its rings and its pool as erx_dma_layout_split_ring lays
 * them out from offset 0, or 0 for a geometry it refuses.
 */
static uint64_t
split_ring_bytes(uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	erx_dma_layout_t layout;

	if (!erx_dma_layout_split_ring(size, buffer_size, granule, UINT64_MAX, 0, 64, &layout))
		return (0);
	return (layout.pool.first + (uint64_t)layout.pool.count * layout.pool.stride);
}

/*
 * The bytes of a queue's memory before its pool and in it. The split ring lays out its rings
 * and pool itself, so its memory is one run, taken as the carve's pool.
 */
static void
queue_bytes(const queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule, uint64_t *rings,
    uint64_t *pool)
{
	*rings = 0;
	*pool = record->form == QUEUE_SPLIT_RING ? split_ring_bytes(size, buffer_size, granule) :
	    (uint64_t)size * granule_round(buffer_size, granule);
}

/*
 * The form's core of a queue whose memory is placed: empty, at the device address its memory
 * gives; a split ring's ledger reads its device's region table. False for a pool the form
 * cannot address, such as one that reaches past GENET's 40 bits.
 */
static bool
core_init(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	if (record->form == QUEUE_REGISTER_RING)
		return (erx_device_genet_init(&record->genet.core, &record->genet.regs, buffer_size, granule,
		    record->device_base + record->pool_offset));
	return (erx_split_ring_make(&record->split.ring, size, buffer_size, granule, record->memory_size,
	    record->device_base, 64, regions_of(record->device)));
}

/*
 * A given device's queue, in the next pages of the device's one memory object: its rings, then
 * its pool. The object is contiguous to the device, so the device address of the rings and the
 * offsets of the queue name all of it. Nothing is read from the memory, which a former record
 * and the device may have written: the install writes the rings whole and hands each buffer
 * over afresh. ERX_ERANGE, taking nothing, for a queue the memory has no room for or the form
 * cannot address; the pages are taken only once everything else has succeeded.
 */
static int
carve_queue_memory(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	const erx_device_t *const device = record->device;
	uint64_t *const taken = &memory_taken[device - devices];
	erx_device_carve_t carve;
	uint64_t pool_addr, rings, pool;
	int status;

	queue_bytes(record, size, buffer_size, granule, &rings, &pool);
	if (!erx_device_carve(*taken, device->memory_size, rings, pool, &carve))
		return (ERX_ERANGE);
	status = erx_mem_dma_addr(device->memory, carve.rings, &record->device_base);
	if (status == ERX_OK)
		status = erx_mem_dma_addr(device->memory, carve.pool, &pool_addr);
	if (status != ERX_OK)
		return (status);
	if (pool_addr - record->device_base != carve.pool - carve.rings)
		return (ERX_ERANGE);
	record->pool_offset = carve.pool - carve.rings;
	record->memory_size = carve.end - carve.rings;
	if (!core_init(record, size, buffer_size, granule))
		return (ERX_ERANGE);
	record->memory = device->dma + carve.rings;
	*taken = carve.end;
	return (ERX_OK);
}

/*
 * A hosted stand-in's queue, in one zeroed block of plain memory on a granule: its rings, then
 * its pool. The split ring's device base is this process's own address of the block, since
 * the stand-in's device is code in this process. A register ring's is a stand-in address
 * below GENET's 40 bits, 4 GiB apart for each record, since this process's addresses may lie
 * above them; the device side finds the record's memory from the record, not the address. No
 * other build has one.
 */
static int
stand_in_queue_memory(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
#ifdef ERX_DEVICE_STAND_IN
	uint64_t rings, pool, bytes;
	uint8_t *memory;

	queue_bytes(record, size, buffer_size, granule, &rings, &pool);
	bytes = rings + pool;
	memory = aligned_alloc(granule, bytes);
	if (memory == NULL)
		return (ERX_ENOMEM);
	bzero(memory, bytes);
	record->device_base = record->form == QUEUE_REGISTER_RING ? (uint64_t)(record - queues + 1) << 32 :
	    (uintptr_t)memory;
	record->pool_offset = rings;
	record->memory_size = bytes;
	if (!core_init(record, size, buffer_size, granule)) {
		free(memory);
		return (ERX_ERANGE);
	}
	record->memory = memory;
	return (ERX_OK);
#else
	(void)record;
	(void)size;
	(void)buffer_size;
	(void)granule;
	return (ERX_ENOTSUP);
#endif
}

static int
place_queue(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	return (record->device->form == ERX_DEVICE_FORM_GIVEN ? carve_queue_memory(record, size, buffer_size, granule) :
	    stand_in_queue_memory(record, size, buffer_size, granule));
}

/* The check's facts every form shares: the queue's memory, the device's window and the granule. */
static erx_dma_context_t
common_facts(const queue_record_t *record, uint32_t granule)
{
	return ((erx_dma_context_t){ .memory_size = record->memory_size, .device_base = record->device_base,
	    .window_size = record->device->peripheral->window_size, .granule = granule });
}

/*
 * A split ring's queue: virtio-mmio version 2's registers and its memory, which the form's core
 * lays out; nothing is installed until a negotiation's reset.
 */
static int
split_ring_create(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	if (!virtio_registers(record->device, &record->split.regs) ||
	    get(record->device, record->split.regs.version) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	return (place_queue(record, size, buffer_size, granule));
}

/* A split ring's layout, which its core made. */
static const erx_dma_layout_t *
split_layout(const queue_record_t *record)
{
	return (erx_dma_ledger_layout(erx_split_ring_ledger(&record->split.ring)));
}

/*
 * One direction of a GENET record, queue 0 receiving or queue 1 transmitting, of 256
 * buffers, one for each of the direction's descriptors. Its registers come from the table, its
 * pool from the device's memory, and the check's facts from the form; the state is the
 * uninstalled queue's, every buffer the CPU's.
 */
static int
register_ring_create(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	register_ring_t *const ring = &record->genet;
	int status;

	if (!erx_device_genet_registers(record->device->peripheral,
	    record->index == GENET_QUEUE_RX ? ERX_DEVICE_GENET_RX : ERX_DEVICE_GENET_TX, &ring->regs))
		return (ERX_ENOTSUP);
	/* Transmit's length field is 12 bits and receive's 16: a buffer past either is the wrong geometry. */
	if (buffer_size > ring->regs.buflen >> __builtin_ctz(ring->regs.buflen) ||
	    buffer_size > ring->regs.buf_length >> __builtin_ctz(ring->regs.buf_length))
		return (ERX_EINVAL);
	status = place_queue(record, size, buffer_size, granule);
	if (status != ERX_OK)
		return (status);
	record->context = common_facts(record, granule);
	erx_device_genet_form(&ring->core, &ring->regs, &ring->length_reg, &record->context);
	erx_device_genet_view(&ring->core, record->pool_offset, &record->state);
	return (ERX_OK);
}

/* A record's geometry, whichever its form. */
static uint32_t
queue_size(const queue_record_t *record)
{
	return (record->form == QUEUE_SPLIT_RING ? split_layout(record)->pool.count : ERX_GENET_RING_SIZE);
}

static uint32_t
queue_buffer_size(const queue_record_t *record)
{
	return (record->form == QUEUE_SPLIT_RING ? split_layout(record)->pool.size : record->genet.core.buffer_size);
}

/* Whether GENET's core has broken the queue, which then refuses every call until the reset. */
static bool
queue_broken(const queue_record_t *record)
{
	return (record->genet.core.broken);
}

/* A register ring broken by a plan the effect layer refused; a split ring's core breaks itself. */
static void
break_queue(queue_record_t *record)
{
	record->genet.core.broken = true;
}

int
erx_device_queue_create(const erx_device_t *device, uint32_t index, uint32_t size, uint32_t buffer_size,
    uint32_t *queue)
{
	const queue_form_t form = register_ring_device(device) ? QUEUE_REGISTER_RING : QUEUE_SPLIT_RING;
	const uint32_t granule = erx_dma_granule();
	queue_record_t *record;
	int status;

	/* A physical device does no DMA, so it has no queue (docs/design-fiasco.md, "Device records"). */
	if (device->form == ERX_DEVICE_FORM_PHYSICAL)
		return (ERX_ENOTSUP);
	if (buffer_size == 0 || buffer_size > ERX_DEVICE_BUFFER_MAX || (form == QUEUE_REGISTER_RING ?
	    index > GENET_QUEUE_TX || size != ERX_GENET_RING_SIZE : split_ring_bytes(size, buffer_size, granule) == 0))
		return (ERX_EINVAL);
	for (uint32_t open = 0; open < queues_open; open++) {
		const queue_record_t *const other = &queues[open];

		if (other->device != device || other->index != index)
			continue;
		if (queue_size(other) != size || queue_buffer_size(other) != buffer_size)
			return (ERX_EBUSY);
		*queue = open;
		return (ERX_OK);
	}
	if (queues_open == ERX_DEVICE_QUEUES_MAX)
		return (ERX_ELIMIT);
	record = &queues[queues_open];
	bzero(record, sizeof(*record));
	record->device = device;
	record->index = index;
	record->form = form;
	status = form == QUEUE_REGISTER_RING ? register_ring_create(record, size, buffer_size, granule) :
	    split_ring_create(record, size, buffer_size, granule);
	if (status != ERX_OK)
		return (status);
	*queue = queues_open++;
	return (ERX_OK);
}

/*
 * The regions. Each record is written whole before regions_open counts it, by a release
 * store, and never changes after, so erx_device_region_memory, which takes no lock, reads
 * only whole records. A region's device address, like a ring's, leaves this file only inside
 * the region entry a post writes.
 */
typedef struct region_record {
	const erx_device_t	*device;
	uint32_t		index;		/* the driver's number for it */
	uint64_t		bytes;		/* what the driver asked for */
	uint64_t		length;		/* its whole pages */
	uint8_t			*mapping;	/* this domain's mapping of it */
	uint64_t		addr;		/* its device address */
} region_record_t;

static region_record_t regions[ERX_DEVICE_REGIONS_MAX];
static _Atomic uint32_t regions_open;

/* The longest region the record's region entry, erx_virtio_gpu_mem_entry with its 32-bit length, can state. */
#define REGION_LENGTH_MAX	UINT32_MAX

/*
 * A given device's region, in the first pages of its memory no queue or region took, its
 * device address from the object and the offset. Its bytes are zeroed, so a new record never
 * shows the device what a former one left. ERX_ERANGE, taking nothing, for no room.
 */
static int
carve_region_memory(region_record_t *record, uint64_t bytes)
{
	const erx_device_t *const device = record->device;
	uint64_t *const taken = &memory_taken[device - devices];
	erx_device_region_carve_t carve;
	int status;

	if (!erx_device_carve_region(*taken, device->memory_size, bytes, REGION_LENGTH_MAX, &carve))
		return (ERX_ERANGE);
	status = erx_mem_dma_addr(device->memory, carve.start, &record->addr);
	if (status != ERX_OK)
		return (status);
	record->length = carve.length;
	record->mapping = device->dma + carve.start;
	bzero(record->mapping, carve.length);
	*taken = carve.end;
	return (ERX_OK);
}

/* A hosted stand-in's region, in zeroed plain memory whose device address is its own; no other build has one. */
static int
stand_in_region_memory(region_record_t *record, uint64_t bytes)
{
#ifdef ERX_DEVICE_STAND_IN
	erx_device_region_carve_t carve;
	uint8_t *mapping;

	if (!erx_device_carve_region(0, REGION_LENGTH_MAX, bytes, REGION_LENGTH_MAX, &carve))
		return (ERX_ERANGE);
	mapping = aligned_alloc(ERX_PAGE_SIZE, carve.length);
	if (mapping == NULL)
		return (ERX_ENOMEM);
	bzero(mapping, carve.length);
	record->length = carve.length;
	record->mapping = mapping;
	record->addr = (uintptr_t)mapping;
	return (ERX_OK);
#else
	(void)record;
	(void)bytes;
	return (ERX_ENOTSUP);
#endif
}

int
erx_device_region(const erx_device_t *device, uint32_t index, uint64_t bytes, uint32_t *region)
{
	const uint32_t open = atomic_load_explicit(&regions_open, memory_order_relaxed);
	region_record_t *record;
	int status;

	/*
	 * A physical device does no DMA, and a device that is not coherent would read a region no
	 * maintenance cleaned (docs/design-device-dma.md, "Regions and writers").
	 */
	if (device->form == ERX_DEVICE_FORM_PHYSICAL || !device->coherent)
		return (ERX_ENOTSUP);
	if (bytes == 0)
		return (ERX_EINVAL);
	for (uint32_t name = 0; name < open; name++) {
		if (regions[name].device != device || regions[name].index != index)
			continue;
		if (regions[name].bytes != bytes)
			return (ERX_EBUSY);
		*region = name;
		return (ERX_OK);
	}
	if (open == ERX_DEVICE_REGIONS_MAX)
		return (ERX_ELIMIT);
	record = &regions[open];
	*record = (region_record_t){ .device = device, .index = index, .bytes = bytes };
	status = device->form == ERX_DEVICE_FORM_GIVEN ? carve_region_memory(record, bytes) :
	    stand_in_region_memory(record, bytes);
	if (status != ERX_OK)
		return (status);
	/* A new name, at most ERX_DEVICE_REGIONS_MAX of them, of a length a region entry states: a refusal is a bug. */
	if (!erx_dma_regions_add(regions_of(device), (erx_dma_persistent_region_t){ .name = open,
	    .address = record->addr, .length = record->length }))
		return (ERX_EINVAL);
	atomic_store_explicit(&regions_open, open + 1, memory_order_release);
	*region = open;
	return (ERX_OK);
}

/* The framebuffer record's window as mapped here: the boot page's record and where it lies. */
typedef struct framebuffer_record {
	uint64_t		window;		/* the record's window object */
	uint64_t		offset;		/* the framebuffer's first byte in the object */
	uint64_t		bytes;		/* the framebuffer's length */
	volatile uint8_t	*mapping;	/* this domain's mapping of the object's first page */
} framebuffer_record_t;

static framebuffer_record_t framebuffers[ERX_DEVICE_FRAMEBUFFERS_MAX];
static _Atomic uint32_t framebuffers_open;

int
erx_device_framebuffer(uint64_t window, uint64_t offset, uint64_t bytes, uint32_t *framebuffer)
{
	const uint32_t open = atomic_load_explicit(&framebuffers_open, memory_order_relaxed);
	uint64_t end, pages, addr;
	int status;

	if (bytes == 0 || offset >= ERX_PAGE_SIZE || __builtin_add_overflow(offset, bytes, &end) ||
	    __builtin_add_overflow(end, ERX_PAGE_SIZE - 1, &pages))
		return (ERX_EINVAL);
	pages &= ~(uint64_t)(ERX_PAGE_SIZE - 1);
	for (uint32_t name = 0; name < open; name++) {
		const framebuffer_record_t *const record = &framebuffers[name];

		if (record->window == window && record->offset == offset && record->bytes == bytes) {
			*framebuffer = name;
			return (ERX_OK);
		}
	}
	if (open == ERX_DEVICE_FRAMEBUFFERS_MAX)
		return (ERX_EBUSY);
	status = map_object(window, 0, pages, &addr);
	if (status != ERX_OK)
		return (status);
	framebuffers[open] = (framebuffer_record_t){ .window = window, .offset = offset, .bytes = bytes,
	    .mapping = (volatile uint8_t *)(uintptr_t)addr };
	atomic_store_explicit(&framebuffers_open, open + 1, memory_order_release);
	*framebuffer = open;
	return (ERX_OK);
}

bool
erx_device_framebuffer_memory(uint32_t framebuffer, volatile uint8_t **base, uint64_t *bytes)
{
	if (framebuffer >= atomic_load_explicit(&framebuffers_open, memory_order_acquire))
		return (false);
	*base = framebuffers[framebuffer].mapping + framebuffers[framebuffer].offset;
	*bytes = framebuffers[framebuffer].bytes;
	return (true);
}

bool
erx_device_region_memory(uint32_t region, uint8_t **base, uint64_t *bytes)
{
	if (region >= atomic_load_explicit(&regions_open, memory_order_acquire))
		return (false);
	*base = regions[region].mapping;
	*bytes = regions[region].length;
	return (true);
}

/*
 * The install's checks for one split-ring queue: the device has let it go, as a reset makes
 * it, and can take its size. They write only the selector, so a refusal changes nothing of
 * any queue.
 */
static int
install_check(const queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->split.regs;

	put(device, regs->sel, record->index);
	if (get(device, regs->ready) != 0)
		return (ERX_EBUSY);
	if (get(device, regs->num_max) < split_layout(record)->pool.count)
		return (ERX_ERANGE);
	return (ERX_OK);
}

/*
 * The effect layer (docs/design-device-dma.md, "Calls, observations and plans"). Every form
 * answers a queue call through one pure round function (erx_device_queue_round,
 * erx_device_genet_round); run_call asks it for round after round. Each round's answers are
 * checked against its copies (answers_fit) and its plan against the record's last state and the
 * state after it, then ordered by the sequencer (accept_plan), all before any effect; then the
 * answers are given to the caller (deliver), the effects run in that order (apply_plan), and
 * the plan's `after` becomes the next plan's `before`. Nothing here chooses a step, a cache operation, a barrier or an order within a
 * call; the order of calls across the two directions of a GENET record is the negotiation's.
 *
 * One plan's steps, states, effects, registers, report values, answers and copy destinations
 * at a time, under the caller's serialisation: together far too large for a scheduler's
 * stack. The largest plan is GENET's install, an address for each of its 256 descriptors and
 * the ring's registers; a split ring's completion, a copy for each range of each entry it
 * takes, comes next.
 */
#define PLAN_MAX(a, b)	((a) > (b) ? (a) : (b))
_Static_assert(ERX_DEVICE_BUFFER_MAX <= ERX_DEVICE_COMPLETE_BYTES, "a completion takes at least one buffer");
#define PLAN_STEPS_MAX	PLAN_MAX(ERX_DEVICE_GENET_INSTALL_STEPS, ERX_DEVICE_COMPLETE_ENTRIES * ERX_DEVICE_CHAIN_MAX)
_Static_assert(PLAN_STEPS_MAX >= ERX_DEVICE_QUEUE_POST_STEPS && PLAN_STEPS_MAX >= ERX_DEVICE_QUEUE_INSTALL_STEPS &&
    PLAN_STEPS_MAX >= ERX_DEVICE_COMPLETE_ENTRIES * ERX_DEVICE_QUEUE_ENTRY_REPORTS &&
    PLAN_STEPS_MAX >= ERX_DEVICE_GENET_POST_STEPS && PLAN_STEPS_MAX >= ERX_DEVICE_COMPLETE_ENTRIES,
    "a plan's steps fit");
_Static_assert(ERX_DEVICE_COMPLETE_ENTRIES <= ERX_DMA_ANSWERS_MAX, "a completion's answers fit");

static erx_dma_step_t plan_steps[PLAN_STEPS_MAX];
static uint64_t plan_values[PLAN_STEPS_MAX];
/* Each register step's registers in the table, low then high, found before any effect runs. */
static const erx_device_register_t *plan_registers[PLAN_STEPS_MAX][2];
static erx_dma_state_t plan_after;
static erx_dma_answer_t plan_answers[ERX_DMA_ANSWERS_MAX];
static uint8_t *plan_destinations[PLAN_STEPS_MAX];
static erx_dma_effect_t plan_effects[ERX_DMA_EFFECTS_BOUND(ERX_DMA_REGIONS_MAX, PLAN_STEPS_MAX)];

/* A ring field's one store or load, of the width the step names: 1, 2, 4 or 8 bytes, aligned. */
static void
store_field(volatile uint8_t *at, uint32_t width, uint64_t value)
{
	switch (width) {
	case 1:
		*at = (uint8_t)value;
		break;
	case 2:
		*(volatile uint16_t *)(volatile void *)at = (uint16_t)value;
		break;
	case 4:
		*(volatile uint32_t *)(volatile void *)at = (uint32_t)value;
		break;
	default:
		*(volatile uint64_t *)(volatile void *)at = value;
		break;
	}
}

static uint64_t
load_field(volatile const uint8_t *at, uint32_t width)
{
	switch (width) {
	case 1:
		return (*at);
	case 2:
		return (*(volatile const uint16_t *)(volatile const void *)at);
	case 4:
		return (*(volatile const uint32_t *)(volatile const void *)at);
	default:
		return (*(volatile const uint64_t *)(volatile const void *)at);
	}
}

/*
 * The table's register for each register step of a plan the check accepted, into
 * plan_registers; false, finding nothing more, for an offset where the table has none, which
 * would be a bug in the form's core, or for one that is not 32 bits wide, the only width the
 * check allows a register step. So every effect of a plan reaches the register at the offset
 * its step names, owned or not, with the width the check saw, and a plan with a step that
 * reaches none runs nothing.
 */
static bool
resolve_registers(const queue_record_t *record, const erx_dma_plan_t *plan)
{
	const erx_device_peripheral_t *const peripheral = record->device->peripheral;

	for (uint32_t at = 0; at < plan->count; at++) {
		const erx_dma_step_t *const step = &plan->steps[at];

		if (step->target != ERX_DMA_REGISTER)
			continue;
		plan_registers[at][0] = register_at(peripheral, step->reg);
		plan_registers[at][1] = step->reg_high == ERX_DMA_NO_REGISTER ? NULL : register_at(peripheral, step->reg_high);
		if (plan_registers[at][0] == NULL || plan_registers[at][0]->width != 32 ||
		    (step->reg_high != ERX_DMA_NO_REGISTER && (plan_registers[at][1] == NULL || plan_registers[at][1]->width != 32)))
			return (false);
	}
	return (true);
}

/*
 * One step of a plan: a write or a publish into the queue's memory or a register at the offset
 * the step names (an address over two registers low word first), a copy out to
 * `destinations[at]`, or a report's one load into `values[at]`.
 */
static void
run_step(const queue_record_t *record, const erx_dma_step_t *step, uint32_t at, uint8_t *const *destinations,
    uint64_t *values)
{
	volatile uint8_t *const memory = record->memory + (step->target == ERX_DMA_MEMORY ? step->offset : 0);
	const erx_device_register_t *const *const regs = plan_registers[at];

	switch (step->kind) {
	case ERX_DMA_WRITE:
	case ERX_DMA_PUBLISH:
		if (step->target == ERX_DMA_REGISTER) {
			store(record->device, regs[0], step->reg, step->reg_high == ERX_DMA_NO_REGISTER ? step->value :
			    step->value & UINT32_MAX);
			if (step->reg_high != ERX_DMA_NO_REGISTER)
				store(record->device, regs[1], step->reg_high, step->value >> 32);
		} else if (step->source == ERX_DMA_BYTES) {
			bcopy(step->bytes, (void *)(uintptr_t)memory, step->length);
		} else if (step->source == ERX_DMA_ZEROS) {
			bzero((void *)(uintptr_t)memory, step->length);
		} else {
			store_field(memory, step->width, step->value);
		}
		break;
	case ERX_DMA_COPY:
		bcopy((const void *)(uintptr_t)memory, destinations[at], step->length);
		break;
	case ERX_DMA_REPORT:
		values[at] = step->target == ERX_DMA_REGISTER ? load(record->device, regs[0], step->reg) :
		    load_field(memory, step->width);
		break;
	}
}

static void
run_effects(const queue_record_t *record, const erx_dma_plan_t *plan, const erx_dma_effects_t *effects,
    uint8_t *const *destinations, uint64_t *values)
{
	for (uint32_t at = 0; at < effects->count; at++) {
		const erx_dma_effect_t *const effect = &effects->effects[at];

		switch (effect->kind) {
		case ERX_DMA_EFFECT_ZERO:
			bzero((void *)(uintptr_t)(record->memory + effect->offset), effect->length);
			break;
		case ERX_DMA_EFFECT_STEP:
			run_step(record, &plan->steps[effect->step], effect->step, destinations, values);
			break;
		case ERX_DMA_EFFECT_CLEAN:
			erx_dma_clean(record->memory + effect->offset, effect->length, effect->line);
			break;
		case ERX_DMA_EFFECT_CLEAN_INVAL:
			erx_dma_clean_inval(record->memory + effect->offset, effect->length, effect->line);
			break;
		case ERX_DMA_EFFECT_BARRIER:
			if (effect->barrier == ERX_DMA_BARRIER_PUBLISH)
				erx_dma_publish_barrier(effect->completes);
			else if (effect->barrier == ERX_DMA_BARRIER_REPORT)
				erx_dma_report_barrier();
			else
				erx_dma_completion_barrier();
			break;
		}
	}
}

/*
 * One round's plan accepted: `plan` from the record's last state to `after` (the record's own
 * state for an observation), checked, ordered into `effects` and its registers resolved, with
 * nothing run. False when the check, the sequencer or the register lookup refuses, which is a
 * bug in the form's core, not an input.
 */
static bool
accept_plan(queue_record_t *record, const erx_dma_plan_t *plan, const erx_dma_state_t *after,
    erx_dma_effects_t *effects)
{
	return (erx_device_dma_check(&record->context, &record->state, after, plan) &&
	    erx_device_dma_order(&record->state, after, plan, record->device->coherent, record->context.granule,
	    erx_dma_line(), effects) && resolve_registers(record, plan));
}

/* An accepted plan run, its copies into `plan_destinations`, and `after` kept as the record's state. */
static void
apply_plan(queue_record_t *record, const erx_dma_plan_t *plan, const erx_dma_effects_t *effects,
    const erx_dma_state_t *after)
{
	run_effects(record, plan, effects, plan_destinations, plan_values);
	if (after != &record->state)
		record->state = *after;
}

/* The record's facts a request carries to its form, which keeps only its own bookkeeping. */
static erx_dma_request_t
queue_request(const queue_record_t *record, erx_dma_request_kind_t kind)
{
	return ((erx_dma_request_t){ .kind = kind, .queue = record->index, .device_base = record->device_base,
	    .pool_offset = record->pool_offset, .ready = record->ready });
}

/* One round of a register ring's form; a split ring's core is called directly (split_ring_post). */
static void
form_round(queue_record_t *record, const erx_dma_request_t *request, erx_dma_round_t *round)
{
	erx_device_genet_round(&record->genet.core, &record->genet.regs, request, round);
}

/*
 * Whether a round's answers cover its plan's copies exactly: each answer's copy steps, in
 * order, fill its `length` bytes end to end, only a completion has copies, and a round with
 * answers has a sink to give them to. False is a bug in the form.
 */
static bool
answers_fit(const erx_dma_round_t *round, erx_device_sink_t *sink)
{
	uint32_t step = 0;

	if (round->answer_count > ERX_DMA_ANSWERS_MAX || (round->answer_count > 0 && sink == NULL))
		return (false);
	for (uint32_t at = 0; at < round->answer_count; at++) {
		const erx_dma_answer_t *const answer = &round->answers[at];
		uint64_t filled = 0;

		for (uint32_t copy = 0; copy < answer->copies; copy++, step++) {
			if (step >= round->count || round->steps[step].kind != ERX_DMA_COPY ||
			    round->steps[step].length > answer->length - filled)
				return (false);
			filled += round->steps[step].length;
		}
		if (filled != answer->length)
			return (false);
	}
	return (round->call == ERX_DMA_CALL_COMPLETE ? step == round->count : round->answer_count == 0);
}

/*
 * Each answer of a round whose answers fit given to the caller: the sink makes the answer's
 * `length` bytes, and the answer's copy steps are pointed at them in order, so a copy reaches
 * only what the sink made for its own tag.
 */
static void
deliver(const erx_dma_round_t *round, erx_device_sink_t *sink, void *context)
{
	uint32_t step = 0;

	for (uint32_t at = 0; at < round->answer_count; at++) {
		const erx_dma_answer_t *const answer = &round->answers[at];
		uint8_t *const into = sink(context, answer->tag, answer->length);
		uint64_t filled = 0;

		for (uint32_t copy = 0; copy < answer->copies; copy++, step++) {
			plan_destinations[step] = into + filled;
			filled += round->steps[step].length;
		}
	}
}

/*
 * One queue call: the form's rounds until the form ends the call, each round's answers and plan
 * checked before any effect, the caller's sinks included, then the answers given and the plan
 * run, with each observation's values handed to the next round. The status is the form's, or
 * ERX_EINVAL when a round's answers or plan are refused or the form does not end within
 * ERX_DMA_ROUNDS_MAX rounds, both bugs in the form's core that break the queue, so its
 * bookkeeping, which may already count the call, is used again only after a reset.
 * `answered` counts the answers given to `sink`; `value` is IDLE's.
 */
static int
run_call(queue_record_t *record, const erx_dma_request_t *request, erx_device_sink_t *sink, void *context,
    uint32_t *answered, uint64_t *value)
{
	uint32_t values = 0, total = 0;

	if (answered != NULL)
		*answered = 0;
	for (uint32_t number = 0; number < ERX_DMA_ROUNDS_MAX; number++) {
		erx_dma_round_t round = { .round = number, .values = plan_values, .value_count = values, .steps = plan_steps,
		    .after = &plan_after, .answers = plan_answers };
		erx_dma_effects_t effects = { .capacity = sizeof(plan_effects) / sizeof(plan_effects[0]),
		    .effects = plan_effects };
		erx_dma_plan_t plan;
		const erx_dma_state_t *after;

		form_round(record, request, &round);
		if (round.ends) {
			if (answered != NULL)
				*answered = total;
			if (value != NULL)
				*value = round.value;
			return (round.status);
		}
		plan = (erx_dma_plan_t){ .call = round.call, .count = round.count, .steps = plan_steps };
		after = round.keeps ? &record->state : &plan_after;
		if (!answers_fit(&round, sink) || !accept_plan(record, &plan, after, &effects)) {
			break_queue(record);
			return (ERX_EINVAL);
		}
		deliver(&round, sink, context);
		apply_plan(record, &plan, &effects, after);
		total += round.answer_count;
		values = round.call == ERX_DMA_CALL_OBSERVE ? round.count : 0;
	}
	break_queue(record);
	return (ERX_EINVAL);
}

/* Every queue of the device stops being ready, at the start of a negotiation and when one fails. */
static void
unready_queues(const erx_device_t *device)
{
	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device)
			queues[open].ready = false;
	}
}

/*
 * A split ring's effects (docs/design-device-dma.md, "Publication", "Releases"). Its core, over
 * the sequencer, decides every byte and register; what follows only applies that, under the
 * caller's lock: stores, cache maintenance and barriers for a device that is or is not
 * coherent, register writes, and the copies a completion gives. One sequence, element batch
 * and answer batch at a time, too large for a scheduler's stack.
 */
static erx_dma_sequence_t ring_sequence;
static erx_report_record_t ring_elements[ERX_DEVICE_COMPLETE_ENTRIES];
static erx_split_ring_answer_t ring_answers[ERX_DEVICE_COMPLETE_ENTRIES];

/*
 * The cache lines of `range` of the queue's memory cleaned, and with `invalidate` invalidated,
 * on a device that is not coherent; nothing on one that is. The memory is whole granules, so
 * rounding to lines stays inside it. True when it maintained anything.
 */
static bool
maintain(const queue_record_t *record, erx_dma_range_t range, bool invalidate)
{
	const uint64_t line = erx_dma_line();
	const uint64_t start = range.offset & ~(line - 1);
	const uint64_t end = (range.offset + range.length + line - 1) & ~(line - 1);

	if (record->device->coherent || range.length == 0)
		return (false);
	if (invalidate)
		erx_dma_clean_inval(record->memory + start, end - start, (uint32_t)line);
	else
		erx_dma_clean(record->memory + start, end - start, (uint32_t)line);
	return (true);
}

/* An install's register, by what it says, onto the device's own (an address low word first). */
static void
put_ring_register(const queue_record_t *record, erx_dma_register_write_t write)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->split.regs;
	const erx_device_register_t *const *address = NULL;

	switch (write.reg) {
	case ERX_DMA_VIRTQ_NUM:
		put(device, regs->num, write.value);
		return;
	case ERX_DMA_VIRTQ_READY:
		put(device, regs->ready, write.value);
		return;
	case ERX_DMA_VIRTQ_DESC:
		address = regs->desc;
		break;
	case ERX_DMA_VIRTQ_DRIVER:
		address = regs->driver;
		break;
	case ERX_DMA_VIRTQ_DEVICE:
		address = regs->device;
		break;
	}
	put(device, address[0], write.value & UINT32_MAX);
	put(device, address[1], write.value >> 32);
}

/*
 * A sequence applied in erx_device_sequencer.h's order: the zeros, the readable pieces' bytes
 * (`pieces[i]` fills sequence->fills[i]), the stores, the clean of every range passing to the
 * device and the publish barrier; then an install's registers after the queue's select, which
 * the core leaves to this layer because virtio-mmio banks them by it (Virtio 1.2, section 4.2.2),
 * and its ready bit; or a run's available index, the clean of its line, a publish barrier and
 * the doorbell. The zeros, fills and stores are plain copies: the device reads none of them
 * before the activation (the ready bit or the available index, itself one store) that follows
 * the publish barrier.
 */
static void
apply_sequence(const queue_record_t *record, const erx_dma_sequence_t *sequence, const erx_dma_piece_t *pieces)
{
	const erx_device_t *const device = record->device;
	const erx_dma_activation_t *const activation = &sequence->activation;
	volatile uint8_t *const memory = record->memory;
	uint64_t value = 0;

	for (uint32_t at = 0; at < sequence->zero_count; at++)
		bzero((void *)(uintptr_t)(memory + sequence->zeros[at].offset), sequence->zeros[at].length);
	for (uint32_t at = 0; at < sequence->fill_count; at++) {
		if (sequence->fills[at].length != 0)
			bcopy(pieces[at].bytes, (void *)(uintptr_t)(memory + sequence->fills[at].offset),
			    sequence->fills[at].length);
	}
	for (uint32_t at = 0; at < sequence->store_count; at++)
		bcopy(sequence->stores[at].bytes, (void *)(uintptr_t)(memory + sequence->stores[at].offset),
		    sequence->stores[at].length);
	for (uint32_t at = 0; at < sequence->clean_count; at++)
		maintain(record, sequence->cleans[at], false);
	erx_dma_publish_barrier(!device->coherent);
	if (activation->kind == ERX_DMA_ACTIVATE_REGISTER) {
		put(device, record->split.regs.sel, record->index);
		for (uint32_t at = 0; at < sequence->register_count; at++)
			put_ring_register(record, sequence->registers[at]);
		put_ring_register(record, activation->reg);
		return;
	}
	/* Little-endian, as the device reads it: the store's bytes are the index's. */
	bcopy(activation->store.bytes, &value, activation->store.length);
	store_field(memory + activation->store.offset, activation->store.length, value);
	maintain(record, (erx_dma_range_t){ activation->store.offset, activation->store.length }, false);
	erx_dma_publish_barrier(!device->coherent);
	put(device, record->split.regs.notify, record->index);
}

/*
 * The install of one split-ring queue, after its checks and the reset's idle report: every ring
 * zeroed and cleaned, so no index a former driver, a former record or the device left in them is
 * ever read, then the queue's size, its rings' addresses and ready (erx_split_ring_install).
 * ERX_EINVAL when the core refuses, which is a bug.
 */
static int
install_apply(queue_record_t *record)
{
	if (erx_split_ring_install(&record->split.ring, &ring_sequence) != ERX_OK)
		return (ERX_EINVAL);
	apply_sequence(record, &ring_sequence, NULL);
	record->ready = true;
	return (ERX_OK);
}

/*
 * The device's idle report: its status reads 0 after the reset, so it holds no chain of any
 * queue, and every split ring of the device ends its chains and is whole again.
 */
static void
reset_queues(const erx_device_t *device)
{
	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device)
			erx_split_ring_reset(&queues[open].split.ring);
	}
}

/*
 * Every queue of the device is checked before any is changed, so a device that refuses has
 * none installed. A plan refused part way, a bug, leaves no queue of the device ready, the
 * ones installed before it included, since the negotiation then marks the device FAILED.
 */
static int
install_queues(const erx_device_t *device)
{
	int status = ERX_OK;

	for (uint32_t open = 0; status == ERX_OK && open < queues_open; open++) {
		if (queues[open].device == device)
			status = install_check(&queues[open]);
	}
	for (uint32_t open = 0; status == ERX_OK && open < queues_open; open++) {
		if (queues[open].device == device)
			status = install_apply(&queues[open]);
	}
	if (status != ERX_OK)
		unready_queues(device);
	return (status);
}


/* The 64 feature bits the device offers, low word then high. */
static uint64_t
offered_features(const erx_device_t *device, const virtio_registers_t *regs)
{
	uint64_t words[2];

	for (uint32_t word = 0; word < 2; word++) {
		put(device, regs->device_features_sel, word);
		words[word] = get(device, regs->device_features) & UINT32_MAX;
	}
	return (words[0] | words[1] << 32);
}

static void
accept_features(const erx_device_t *device, const virtio_registers_t *regs, uint64_t accepted)
{
	for (uint32_t word = 0; word < 2; word++) {
		put(device, regs->driver_features_sel, word);
		put(device, regs->driver_features, (accepted >> (32 * word)) & UINT32_MAX);
	}
}

/*
 * Virtio's initialisation, section 3.1.1, whole: the reset, ACKNOWLEDGE and DRIVER, the
 * features, FEATURES_OK read back, every queue of the device installed, and DRIVER_OK. Every
 * queue stops being ready before the reset, so nothing is posted while the device may still
 * hold an old descriptor, and is ready again only after this reset. A step that fails sets
 * FAILED, so the device stays unusable until the next negotiation resets it.
 */
static int
split_ring_negotiate(const erx_device_t *device, uint64_t wanted, uint64_t *accepted)
{
	virtio_registers_t regs;
	uint64_t device_status, taken;
	int result = ERX_OK;

	if (!virtio_registers(device, &regs) || get(device, regs.version) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	put(device, regs.status, 0);
	if (get(device, regs.status) != 0)
		return (ERX_EBUSY);
	reset_queues(device);
	device_status = regs.acknowledge;
	put(device, regs.status, device_status);
	device_status |= regs.driver_bit;
	put(device, regs.status, device_status);
	if (!erx_device_queue_features(wanted, offered_features(device, &regs), &taken))
		result = ERX_ENOTSUP;
	if (result == ERX_OK) {
		accept_features(device, &regs, taken);
		device_status |= regs.features_ok;
		put(device, regs.status, device_status);
		if ((get(device, regs.status) & regs.features_ok) == 0)
			result = ERX_ENOTSUP;
	}
	if (result == ERX_OK)
		result = install_queues(device);
	if (result != ERX_OK) {
		put(device, regs.status, device_status | regs.failed);
		return (result);
	}
	put(device, regs.status, device_status | regs.driver_ok);
	*accepted = taken;
	return (ERX_OK);
}

/* The device's queue of its own number `index`, or NULL. */
static queue_record_t *
queue_numbered(const erx_device_t *device, uint32_t index)
{
	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device && queues[open].index == index)
			return (&queues[open]);
	}
	return (NULL);
}

/*
 * GENET's reset and install (docs/design-device-dma.md, "Install and reset"), across the two
 * directions in the order the design gives, which is why it lives here and not in the
 * per-direction form: DMA control stopped, transmit then receive; each direction's DMA status
 * read once by its IDLE call; ERX_EBUSY, with nothing installed and both engines left stopped,
 * until both show the stop, so a later call writes the stop again and reads again; then each
 * queue's INSTALL call, which takes every buffer back and installs its ring, receive then
 * transmit; and only once both rings are installed, each START call, receive first. The
 * features mean nothing to GENET: none are accepted. A record without both its queues is
 * ERX_EINVAL; a refused plan, a bug, leaves both queues not ready.
 */
static int
register_ring_negotiate(const erx_device_t *device, uint64_t *accepted)
{
	queue_record_t *const rings[2] = { queue_numbered(device, GENET_QUEUE_RX), queue_numbered(device, GENET_QUEUE_TX) };
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	uint64_t status[2];
	bool idle = true;

	if (rings[0] == NULL || rings[1] == NULL)
		return (ERX_EINVAL);
	for (uint32_t side = 2; side-- > 0;) {
		const erx_device_genet_registers_t *const regs = &rings[side]->genet.regs;
		const erx_device_register_t *const ctrl = register_at(peripheral, regs->dma_ctrl);

		if (ctrl == NULL)
			return (ERX_ENOTSUP);
		put(device, ctrl, erx_device_genet_stop(regs));
	}
	for (uint32_t side = 0; side < 2; side++) {
		const erx_dma_request_t request = queue_request(rings[side], ERX_DMA_REQUEST_IDLE);
		const int shown = run_call(rings[side], &request, NULL, NULL, NULL, &status[side]);

		if (shown != ERX_OK && shown != ERX_EBUSY)
			return (ERX_EINVAL);
		idle = idle && shown == ERX_OK;
	}
	if (!idle)
		return (ERX_EBUSY);
	for (uint32_t side = 0; side < 2; side++) {
		erx_dma_request_t request = queue_request(rings[side], ERX_DMA_REQUEST_INSTALL);

		request.idle = status[side];
		if (run_call(rings[side], &request, NULL, NULL, NULL, NULL) != ERX_OK)
			return (ERX_EINVAL);
	}
	for (uint32_t side = 0; side < 2; side++) {
		const erx_dma_request_t request = queue_request(rings[side], ERX_DMA_REQUEST_START);

		if (run_call(rings[side], &request, NULL, NULL, NULL, NULL) != ERX_OK)
			return (ERX_EINVAL);
	}
	rings[0]->ready = rings[1]->ready = true;
	*accepted = 0;
	return (ERX_OK);
}

int
erx_device_negotiate(const erx_device_t *device, uint64_t wanted, uint64_t *accepted)
{
	unready_queues(device);
	if (register_ring_device(device))
		return (register_ring_negotiate(device, accepted));
	return (split_ring_negotiate(device, wanted, accepted));
}

static queue_record_t *
queue_of(const erx_device_t *device, uint32_t queue)
{
	return (queue < queues_open && queues[queue].device == device ? &queues[queue] : NULL);
}

/*
 * A post's pieces as the forms take them. A region piece names the region alone: the split
 * ring's core writes its entry from the device's region table, so the device learns a region's
 * address only from the NIF, and only for its own device's region.
 */
static void
form_pieces(const erx_device_piece_t *requested, uint32_t count, erx_dma_piece_t *pieces)
{
	for (uint32_t step = 0; step < count; step++)
		pieces[step] = (erx_dma_piece_t){ .bytes = requested[step].data, .length = requested[step].length,
		    .device_writes = requested[step].device_writes, .names_region = requested[step].names_region,
		    .region = requested[step].region };
}

/* A split ring's post: the core's sequence, applied whole, or its refusal with nothing applied. */
static int
split_ring_post(queue_record_t *record, uint64_t tag, const erx_dma_piece_t *pieces, uint32_t count)
{
	const int status = erx_split_ring_post(&record->split.ring, pieces, count, tag, &ring_sequence);

	if (status == ERX_OK)
		apply_sequence(record, &ring_sequence, pieces);
	return (status);
}

int
erx_device_post(const erx_device_t *device, uint32_t queue, uint64_t tag, const erx_device_piece_t *requested,
    uint32_t count)
{
	queue_record_t *const record = queue_of(device, queue);
	erx_dma_piece_t pieces[ERX_DEVICE_CHAIN_MAX];
	erx_dma_request_t request;

	if (record == NULL || count == 0 || count > ERX_DEVICE_CHAIN_MAX)
		return (ERX_EINVAL);
	form_pieces(requested, count, pieces);
	if (record->form == QUEUE_SPLIT_RING)
		return (record->ready ? split_ring_post(record, tag, pieces, count) : ERX_ECORRUPT);
	request = queue_request(record, ERX_DMA_REQUEST_POST);
	request.tag = tag;
	request.count = count;
	request.pieces = pieces;
	return (run_call(record, &request, NULL, NULL, NULL, NULL));
}

/*
 * A split ring's completion: on a device that is not coherent, each structure the device wrote
 * invalidated before it is read. The used index is loaded once and the core acquires what it
 * covers; each element is read whole and the core completes them; then each answer's written
 * range is copied to what the sink gives for its tag.
 */
static int
split_ring_complete(queue_record_t *record, erx_device_sink_t *sink, void *context, uint32_t *completed)
{
	erx_split_ring_t *const ring = &record->split.ring;
	const erx_dma_layout_t *const layout = split_layout(record);
	const erx_dma_table_t *const used =
	    &layout->tables[erx_dma_ledger_table(erx_split_ring_ledger(ring), ERX_STRUCTURE_VIRTQ_USED)];
	const erx_dma_range_t index_at = { used->region + offsetof(erx_virtq_ring_head_t, idx), sizeof(uint16_t) };
	uint32_t count, done;
	bool maintained;
	int status;

	if (maintain(record, index_at, true))
		erx_dma_completion_barrier();
	status = erx_split_ring_acquire(ring, (uint16_t)load_field(record->memory + index_at.offset, sizeof(uint16_t)),
	    ERX_DEVICE_COMPLETE_ENTRIES, &count);
	erx_dma_report_barrier();
	if (status != ERX_OK)
		return (status);
	maintained = false;
	for (uint32_t k = 0; k < count; k++)
		maintained |= maintain(record, erx_split_ring_element(ring, k), true);
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t k = 0; k < count; k++) {
		const erx_dma_range_t element = erx_split_ring_element(ring, k);

		bcopy((const void *)(uintptr_t)(record->memory + element.offset), ring_elements[k].bytes, element.length);
	}
	erx_dma_report_barrier();
	status = erx_split_ring_complete(ring, ring_elements, count, ERX_DEVICE_COMPLETE_BYTES, ring_answers, &done);
	if (status != ERX_OK)
		return (status);
	maintained = false;
	for (uint32_t at = 0; at < done; at++)
		maintained |= maintain(record, ring_answers[at].written, true);
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t at = 0; at < done; at++) {
		const erx_dma_range_t written = ring_answers[at].written;
		uint8_t *const into = sink(context, ring_answers[at].tag, (uint32_t)written.length);

		if (written.length != 0)
			bcopy((const void *)(uintptr_t)(record->memory + written.offset), into, written.length);
	}
	*completed = done;
	return (ERX_OK);
}

int
erx_device_complete(const erx_device_t *device, uint32_t queue, erx_device_sink_t *sink, void *context,
    uint32_t *completed)
{
	queue_record_t *const record = queue_of(device, queue);
	erx_dma_request_t request;

	*completed = 0;
	if (record == NULL)
		return (ERX_EINVAL);
	if (record->form == QUEUE_SPLIT_RING)
		return (record->ready ? split_ring_complete(record, sink, context, completed) : ERX_ECORRUPT);
	if (!record->ready || queue_broken(record))
		return (ERX_ECORRUPT);
	request = queue_request(record, ERX_DMA_REQUEST_COMPLETE);
	request.answers_max = ERX_DEVICE_COMPLETE_ENTRIES;
	request.bytes_max = ERX_DEVICE_COMPLETE_BYTES;
	return (run_call(record, &request, sink, context, completed, NULL));
}

#ifdef ERX_DEVICE_STAND_IN
/*
 * The stand-in's device writes the used ring as any device may, honest or not; only the
 * driver side, erx_device_complete, judges what it wrote. The device's own count of what it
 * consumed is the used index, so the next available head is the one at that position.
 */
int
erx_device_stand_in_used(const erx_device_t *device, uint32_t queue, const erx_device_used_entry_t *entries,
    uint32_t count)
{
	const queue_record_t *const record = queue_of(device, queue);
	const erx_dma_ledger_t *ledger;
	const erx_dma_table_t *avail, *used_table;
	volatile erx_virtq_ring_head_t *used;
	volatile erx_virtq_used_elem_t *elems;
	volatile const uint16_t *avail_ring;
	uint32_t mask;
	uint16_t idx;

	if (record == NULL || device->form != ERX_DEVICE_FORM_STAND_IN || record->form != QUEUE_SPLIT_RING ||
	    !record->ready || count > split_layout(record)->pool.count)
		return (ERX_EINVAL);
	/* The device finds its rings where the install's registers put them: the core's layout. */
	ledger = erx_split_ring_ledger(&record->split.ring);
	avail = &split_layout(record)->tables[erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_AVAIL)];
	used_table = &split_layout(record)->tables[erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_USED)];
	mask = used_table->count - 1;
	used = (volatile erx_virtq_ring_head_t *)(record->memory + used_table->region);
	elems = (volatile erx_virtq_used_elem_t *)(record->memory + used_table->first);
	avail_ring = (volatile const uint16_t *)(record->memory + avail->first);
	idx = used->idx;
	for (uint32_t entry = 0; entry < count; entry++) {
		const uint32_t slot = (uint32_t)(idx + entry) & mask;

		elems[slot].id = entries[entry].next ? avail_ring[slot] : entries[entry].id;
		elems[slot].len = entries[entry].length;
	}
	atomic_thread_fence(memory_order_release);
	used->idx = (uint16_t)(idx + count);
	return (ERX_OK);
}

/*
 * The stand-in GENET's engines, run when a test asks, under the caller's lock as every queue
 * call is: erx_device_genet_model's, over the window and the installed ring's memory. The
 * model reaches each buffer through the address its descriptor holds, found in the record's
 * memory by the record's device base; it is never derived from the NIF's bookkeeping, so a
 * wrong published address shows as a refused or misplaced frame.
 */

/* The installed register ring of a stand-in GENET in one direction, or NULL. */
static const queue_record_t *
stand_in_genet_ring(const erx_device_t *device, uint32_t index)
{
	for (uint32_t at = 0; device->form == ERX_DEVICE_FORM_STAND_IN && at < queues_open; at++) {
		const queue_record_t *const record = &queues[at];

		if (record->device == device && record->form == QUEUE_REGISTER_RING && record->index == index &&
		    record->ready)
			return (record);
	}
	return (NULL);
}

/* The `length` bytes at device address `addr` in the record's memory, or NULL when they are not all in it. */
static volatile uint8_t *
stand_in_genet_bytes(const queue_record_t *record, uint64_t addr, uint32_t length)
{
	if (addr < record->device_base || addr - record->device_base > record->memory_size ||
	    length > record->memory_size - (addr - record->device_base))
		return (NULL);
	return (record->memory + (addr - record->device_base));
}

static bool
stand_in_genet_read(void *context, uint64_t addr, uint8_t *bytes, uint32_t length)
{
	volatile uint8_t *const from = stand_in_genet_bytes(context, addr, length);

	if (from == NULL)
		return (false);
	if (length != 0)
		bcopy((const void *)(uintptr_t)from, bytes, length);
	return (true);
}

static bool
stand_in_genet_write(void *context, uint64_t addr, const uint8_t *bytes, uint32_t length)
{
	volatile uint8_t *const to = stand_in_genet_bytes(context, addr, length);

	if (to == NULL)
		return (false);
	if (length != 0)
		bcopy(bytes, (void *)(uintptr_t)to, length);
	return (true);
}

/* The model's device memory: the ring's queue memory, which the stand-in's DMA reaches by device address. */
static erx_device_genet_memory_t
stand_in_genet_memory(const queue_record_t *record)
{
	return ((erx_device_genet_memory_t){ .context = (void *)(uintptr_t)record, .read = stand_in_genet_read,
	    .write = stand_in_genet_write });
}

int
erx_device_stand_in_transmitted(const erx_device_t *device, erx_device_sink_t *sink, void *context, uint32_t *sent)
{
	const queue_record_t *const record = stand_in_genet_ring(device, GENET_QUEUE_TX);
	erx_device_genet_model_t genet;
	erx_device_genet_memory_t memory;

	*sent = 0;
	if (record == NULL || !stand_in_genet_model(device, &genet))
		return (ERX_EINVAL);
	memory = stand_in_genet_memory(record);
	return (erx_device_genet_model_transmit(&genet, &memory, sink, context, sent));
}

int
erx_device_stand_in_receive(const erx_device_t *device, const erx_device_frame_t *frames, uint32_t count,
    uint32_t *taken)
{
	const queue_record_t *const record = stand_in_genet_ring(device, GENET_QUEUE_RX);
	const erx_device_register_t *rbuf_ctrl;
	const erx_device_field_t *align, *status_block;
	erx_device_genet_model_t genet;
	erx_device_genet_memory_t memory;
	uint32_t control, pad, reach;
	bool aligned, took;

	*taken = 0;
	if (record == NULL || !stand_in_genet_model(device, &genet) ||
	    (rbuf_ctrl = plain_register(device, "rbuf_ctrl")) == NULL ||
	    (align = stand_in_field(device, rbuf_ctrl, "align_2b")) == NULL ||
	    (status_block = stand_in_field(device, rbuf_ctrl, "status_64b")) == NULL)
		return (ERX_EINVAL);
	control = erx_device_access_load32(device->windows[0], rbuf_ctrl->offset);
	/* The stand-in lays out no 64-byte status block, so it takes nothing while one is asked for. */
	if ((control & status_block->mask) != 0)
		return (ERX_EINVAL);
	/* ALIGN_2B: two bytes of padding before each frame, which the length counts. */
	aligned = (control & align->mask) != 0;
	pad = aligned ? 2u : 0u;
	/* Every frame fits its buffer, or none is taken. */
	reach = erx_device_genet_model_buffer_bytes(&genet, ERX_DEVICE_GENET_RX);
	for (uint32_t frame = 0; frame < count; frame++) {
		if (reach < pad || frames[frame].length > reach - pad)
			return (ERX_EINVAL);
	}
	memory = stand_in_genet_memory(record);
	for (; *taken < count; (*taken)++) {
		const erx_device_genet_model_frame_t frame = { .bytes = frames[*taken].bytes,
		    .written = frames[*taken].length, .length = frames[*taken].length, .aligned = aligned,
		    .flags = genet.regs[ERX_DEVICE_GENET_RX].sop | genet.regs[ERX_DEVICE_GENET_RX].eop };
		const int status = erx_device_genet_model_receive(&genet, &memory, &frame, &took);

		/* A stopped engine or a full ring is no fault: the rest wait for buffers the driver hands back. */
		if (status != ERX_OK || !took)
			return (status);
	}
	return (ERX_OK);
}
#endif
