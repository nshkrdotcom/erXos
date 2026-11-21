/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lookups by text, over the generated table. This is the one source that includes it.
 */

#include "erx_device_core.h"

#include "erx/hw/device_table.h"

static bool
same_text(const char *name, const char *text, size_t length)
{
	size_t at = 0;

	while (at < length && name[at] != '\0' && name[at] == text[at])
		at++;
	return (at == length && name[at] == '\0');
}

static size_t
text_length(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (length);
}

const erx_device_peripheral_t *
erx_device_peripheral_find(const char *name, size_t length)
{
	for (size_t index = 0; index < sizeof(erx_device_peripherals) / sizeof(erx_device_peripherals[0]); index++) {
		if (same_text(erx_device_peripherals[index].name, name, length))
			return (&erx_device_peripherals[index]);
	}
	return (NULL);
}

/*
 * Whether the peripheral is the one named or derives from it: a kind whose table begins
 * with that peripheral's registers, at their indices there (tools/lib/erx/hardware.rb,
 * derived_cluster).
 */
bool
erx_device_peripheral_is(const erx_device_peripheral_t *peripheral, const char *name)
{
	const size_t length = text_length(name);

	return (peripheral != NULL && (same_text(peripheral->name, name, length) ||
	    (peripheral->derived_from != NULL && same_text(peripheral->derived_from, name, length))));
}

uint32_t
erx_device_register_named(const erx_device_peripheral_t *peripheral, const char *name)
{
	const size_t length = text_length(name);
	uint32_t index = 0;

	while (index < peripheral->register_count && !same_text(peripheral->registers[index].name, name, length))
		index++;
	return (index);
}

uint32_t
erx_device_field_named(const erx_device_peripheral_t *peripheral, const erx_device_register_t *reg, const char *name)
{
	const size_t length = text_length(name);
	uint32_t index = 0;

	while (index < reg->field_count && !same_text(peripheral->fields[reg->first_field + index].name, name, length))
		index++;
	return (index);
}

const erx_device_space_t *
erx_device_space_named(const erx_device_peripheral_t *peripheral, const char *name, size_t length)
{
	for (uint32_t index = 0; index < peripheral->space_count; index++) {
		if (same_text(peripheral->spaces[index].name, name, length))
			return (&peripheral->spaces[index]);
	}
	return (NULL);
}

uint32_t
erx_device_space_blocks(const erx_device_space_t *space, uint64_t size)
{
	const uint64_t whole = space->offset > size ? 0 : (size - space->offset) / space->size;

	return (whole < space->count ? (uint32_t)whole : space->count);
}

bool
erx_device_space_offset(const erx_device_space_t *space, uint64_t size, bool indexed, uint64_t index,
    uint64_t offset, uint64_t width, uint64_t *at)
{
	if (indexed != (space->count > 1) || index >= erx_device_space_blocks(space, size) ||
	    (width != 1 && width != 2 && width != 4) || offset % width != 0 || offset >= space->size ||
	    width > space->size - offset)
		return (false);
	*at = space->offset + index * space->size + offset;
	return (true);
}

/* An extended-capability list entry's first word: its ID, and the next entry's offset in 32-bit words. */
#define LIST_ID_MASK	UINT64_C(0xff)
#define LIST_NEXT_SHIFT	8u
#define LIST_NEXT_MASK	UINT64_C(0xff)
#define LIST_WORD_BYTES	4u

/* Whether the register at `index` is read before the walk: a base, a count or the list's head comes from it. */
static bool
is_source(const erx_device_peripheral_t *peripheral, uint32_t index)
{
	if (peripheral->listed && peripheral->list_reg == index)
		return (true);
	for (uint32_t at = 0; at < peripheral->base_count; at++) {
		if (peripheral->bases[at].capability == 0 && peripheral->bases[at].reg == index)
			return (true);
	}
	for (uint32_t at = 0; at < peripheral->register_count; at++) {
		if (peripheral->registers[at].counted && peripheral->registers[at].count_register == index)
			return (true);
	}
	return (false);
}

/* What the word of source register `index` gives: the bases whose field it holds, in place, the counts, and the list's head. */
static void
take_source(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout, erx_device_resolve_t *resolve,
    uint32_t index, uint64_t word)
{
	for (uint32_t at = 0; at < peripheral->base_count; at++) {
		const erx_device_base_t *const base = &peripheral->bases[at];

		if (base->capability == 0 && base->reg == index)
			layout->slot[base->first] = word & peripheral->fields[base->field].mask;
	}
	for (uint32_t at = 0; at < peripheral->register_count; at++) {
		const erx_device_register_t *const reg = &peripheral->registers[at];

		if (reg->counted && reg->count_register == index)
			layout->elements[at] = (uint32_t)erx_device_field_get(&peripheral->fields[reg->count_field], word);
	}
	if (peripheral->listed && peripheral->list_reg == index)
		resolve->entry = erx_device_field_get(&peripheral->fields[peripheral->list_field], word) * LIST_WORD_BYTES;
}

/*
 * The entry being read, with ID `id`, as the next instance of the cluster of that capability;
 * false when every instance is taken. An ID no cluster has is passed over.
 */
static bool
take_entry(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout, erx_device_resolve_t *resolve,
    uint64_t id)
{
	for (uint32_t at = 0; at < peripheral->base_count; at++) {
		const erx_device_base_t *const base = &peripheral->bases[at];

		if (base->capability == 0 || base->capability != id)
			continue;
		if (resolve->found[at] == base->instances)
			return (false);
		layout->slot[base->first + resolve->found[at]++] = resolve->entry;
		return (true);
	}
	return (true);
}

/*
 * The bytes each place of a layout's registers covers, from its first element's first byte to
 * its last element's last: place 0 is the registers at fixed offsets, and place 1 + n slot n's
 * cluster instance, and the last, KEPT_PLACE, the span the open keeps apart. A place with no
 * element has first UINT64_MAX.
 */
#define PLACES		(2 + ERX_DEVICE_SLOTS_MAX)
#define KEPT_PLACE	(PLACES - 1)

typedef struct places {
	uint64_t	first[PLACES];
	uint64_t	end[PLACES];
} places_t;

static uint32_t
place_of(const erx_device_peripheral_t *peripheral, const erx_device_register_t *reg, uint32_t index)
{
	const erx_device_base_t *cluster;

	if (reg->base == 0)
		return (0);
	cluster = &peripheral->bases[reg->base - 1];
	return (1 + cluster->first + (cluster->instances > 1 ? index : 0));
}

/*
 * Whether every element of the register lies wholly inside the window, at an offset aligned to
 * its width; each widens its place's bytes.
 */
static bool
elements_inside(const erx_device_peripheral_t *peripheral, const erx_device_layout_t *layout,
    const erx_device_register_t *reg, uint64_t size, places_t *places)
{
	const uint64_t bytes = reg->width / 8u;
	uint64_t offset;

	for (uint32_t index = 0; index < layout->elements[reg - peripheral->registers]; index++) {
		const uint32_t place = place_of(peripheral, reg, index);

		if (!erx_device_layout_offset(peripheral, layout, reg, reg->count > 1, index, &offset) ||
		    offset % bytes != 0 || offset > size || bytes > size - offset)
			return (false);
		if (offset < places->first[place])
			places->first[place] = offset;
		if (offset + bytes > places->end[place])
			places->end[place] = offset + bytes;
	}
	return (true);
}

/*
 * Whether no two places share a byte. Within a place the generator keeps registers apart; a
 * device that reported bases putting one cluster over another, or over the fixed registers,
 * would give a register a driver may write the address of one the NIF owns.
 */
static bool
places_apart(const places_t *places)
{
	for (uint32_t a = 0; a < PLACES; a++) {
		for (uint32_t b = a + 1; b < PLACES; b++) {
			if (places->first[a] < places->end[b] && places->first[b] < places->end[a])
				return (false);
		}
	}
	return (true);
}

/*
 * The walk's end: each capability cluster's registers have the instances found, every element
 * must fit the window, and no cluster instance may overlap another, the fixed registers or the
 * kept span.
 */
static void
finish(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout, erx_device_resolve_t *resolve)
{
	places_t places;
	bool fits = true;

	for (uint32_t place = 0; place < PLACES; place++) {
		places.first[place] = UINT64_MAX;
		places.end[place] = 0;
	}
	places.first[KEPT_PLACE] = resolve->kept_first;
	places.end[KEPT_PLACE] = resolve->kept_end;
	for (uint32_t index = 0; index < peripheral->register_count; index++) {
		const erx_device_register_t *const reg = &peripheral->registers[index];
		const erx_device_base_t *const base = reg->base != 0 ? &peripheral->bases[reg->base - 1] : NULL;

		if (base != NULL && base->capability != 0) {
			const uint32_t found = resolve->found[reg->base - 1];

			/* An array cluster's registers have an element in each instance found; a single one's are absent without it. */
			if (base->instances > 1)
				layout->elements[index] = found;
			else if (found == 0)
				layout->elements[index] = 0;
		}
		fits = fits && elements_inside(peripheral, layout, reg, resolve->size, &places);
	}
	resolve->op = fits && places_apart(&places) ? ERX_DEVICE_RESOLVE_DONE : ERX_DEVICE_RESOLVE_REFUSED;
}

static void
ask(erx_device_resolve_t *resolve, uint64_t offset, uint8_t width)
{
	resolve->op = ERX_DEVICE_RESOLVE_READ;
	resolve->offset = offset;
	resolve->width = width;
}

/* The next read the resolution needs: the next source, then the list's next entry, else its end. */
static void
advance(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout, erx_device_resolve_t *resolve)
{
	while (resolve->next < peripheral->register_count && !is_source(peripheral, resolve->next))
		resolve->next++;
	if (resolve->next < peripheral->register_count) {
		ask(resolve, peripheral->registers[resolve->next].offset, peripheral->registers[resolve->next].width);
		return;
	}
	if (resolve->entry == 0) {
		finish(peripheral, layout, resolve);
		return;
	}
	if (resolve->entries == ERX_DEVICE_LIST_ENTRIES_MAX || resolve->size < LIST_WORD_BYTES ||
	    resolve->entry > resolve->size - LIST_WORD_BYTES) {
		resolve->op = ERX_DEVICE_RESOLVE_REFUSED;
		return;
	}
	ask(resolve, resolve->entry, 32);
}

void
erx_device_resolve_begin(const erx_device_peripheral_t *peripheral, uint64_t size, uint64_t kept, uint64_t kept_bytes,
    erx_device_layout_t *layout, erx_device_resolve_t *resolve)
{
	*layout = (erx_device_layout_t){ 0 };
	*resolve = (erx_device_resolve_t){ .size = size, .kept_first = kept_bytes == 0 ? UINT64_MAX : kept,
	    .kept_end = kept_bytes == 0 ? 0 : kept + kept_bytes };
	for (uint32_t index = 0; index < peripheral->register_count; index++)
		layout->elements[index] = peripheral->registers[index].count;
	advance(peripheral, layout, resolve);
}

void
erx_device_resolve_step(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout,
    erx_device_resolve_t *resolve, uint64_t word)
{
	if (resolve->op != ERX_DEVICE_RESOLVE_READ)
		return;
	if (resolve->next < peripheral->register_count) {
		take_source(peripheral, layout, resolve, resolve->next++, word);
	} else {
		const uint64_t next = (word >> LIST_NEXT_SHIFT) & LIST_NEXT_MASK;

		resolve->entries++;
		if (!take_entry(peripheral, layout, resolve, word & LIST_ID_MASK)) {
			resolve->op = ERX_DEVICE_RESOLVE_REFUSED;
			return;
		}
		resolve->entry = next == 0 ? 0 : resolve->entry + next * LIST_WORD_BYTES;
	}
	advance(peripheral, layout, resolve);
}
