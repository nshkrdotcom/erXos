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
	/* Each register is read once, so no more than ERX_DEVICE_REGISTERS_MAX are. */
	resolve->source[resolve->sources++] = (erx_device_source_word_t){ .reg = index, .word = word };
	for (uint32_t at = 0; at < peripheral->base_count; at++) {
		const erx_device_base_t *const base = &peripheral->bases[at];

		if (base->capability == 0 && base->reg == index)
			layout->slot[base->first] = word & peripheral->fields[base->field].mask;
	}
	for (uint32_t at = 0; at < peripheral->register_count; at++) {
		const erx_device_register_t *const reg = &peripheral->registers[at];

		if (reg->counted && reg->count_register == index)
			layout->elements[at] = (uint32_t)erx_device_field_get(&peripheral->fields[reg->count_field], word) +
			    reg->count_plus;
	}
	if (peripheral->listed && peripheral->list_reg == index)
		resolve->entry = erx_device_field_get(&peripheral->fields[peripheral->list_field], word) * LIST_WORD_BYTES;
}

/* The resolution's end in refusal, by the rule `refusal` names. */
static void
refuse(erx_device_resolve_t *resolve, erx_device_refusal_t refusal)
{
	resolve->op = ERX_DEVICE_RESOLVE_REFUSED;
	resolve->refusal = refusal;
}

/*
 * The entry being read, with ID `id`, as the next instance of the cluster of that capability;
 * refused, false, when every instance is taken. An ID no cluster has is passed over.
 */
static bool
take_entry(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout, erx_device_resolve_t *resolve,
    uint64_t id)
{
	for (uint32_t at = 0; at < peripheral->base_count; at++) {
		const erx_device_base_t *const base = &peripheral->bases[at];

		if (base->capability == 0 || base->capability != id)
			continue;
		if (resolve->found[at] == base->instances) {
			refuse(resolve, (erx_device_refusal_t){ .rule = ERX_DEVICE_REFUSAL_TOO_MANY, .base = at });
			return (false);
		}
		layout->slot[base->first + resolve->found[at]++] = resolve->entry;
		return (true);
	}
	return (true);
}

/*
 * The places a layout's registers lie in: place 0 the registers at fixed offsets, place 1 + n
 * slot n's cluster instance, and the last, KEPT_PLACE, the span the open keeps apart.
 */
#define PLACES		(2 + ERX_DEVICE_SLOTS_MAX)
#define KEPT_PLACE	(PLACES - 1)

/*
 * The bytes one register covers in one place, from its first element's first byte there to its
 * last element's end: for most registers their whole array, for a register of an array cluster
 * its one element in each instance. The kept span is a span of KEPT_PLACE.
 */
typedef struct span {
	uint32_t	place;
	uint64_t	first;
	uint64_t	end;
} span_t;

/* Every register's span, in each instance of an array cluster, then the kept span. */
typedef struct spans {
	uint32_t	count;
	span_t		span[ERX_DEVICE_SPANS_MAX + 1];
} spans_t;

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
 * its width, refused at the first that does not; each element opens the register's span in its
 * place or widens it. A register's elements in one place lie at rising offsets, its stride at
 * least its width, so the last one's end is the span's.
 */
static bool
elements_inside(const erx_device_peripheral_t *peripheral, const erx_device_layout_t *layout,
    const erx_device_register_t *reg, erx_device_resolve_t *resolve, spans_t *spans)
{
	const uint64_t bytes = reg->width / 8u, size = resolve->size;
	const uint32_t at = (uint32_t)(reg - peripheral->registers);
	/* A register of an array cluster has its element in each instance, each a span of its own. */
	const bool instanced = reg->base != 0 && peripheral->bases[reg->base - 1].instances > 1;
	uint64_t offset;

	for (uint32_t index = 0; index < layout->elements[at]; index++) {
		const uint32_t place = place_of(peripheral, reg, index);
		const bool known = erx_device_layout_offset(peripheral, layout, reg, reg->count > 1, index, &offset);
		erx_device_refusal_rule_t rule;

		if (!known || offset > size || bytes > size - offset)
			rule = ERX_DEVICE_REFUSAL_PAST_WINDOW;
		else if (offset % bytes != 0)
			rule = ERX_DEVICE_REFUSAL_UNALIGNED;
		else
			rule = ERX_DEVICE_REFUSAL_NONE;
		if (rule != ERX_DEVICE_REFUSAL_NONE) {
			refuse(resolve, (erx_device_refusal_t){ .rule = rule, .reg = at, .index = index, .offset_known = known,
			    .offset = known ? offset : 0, .bytes = bytes });
			return (false);
		}
		/*
		 * One span for each register, or for each instance of an instanced one, whose index
		 * erx_device_layout_offset keeps below its count: at most ERX_DEVICE_SPANS_MAX.
		 */
		if (index == 0 || instanced)
			spans->span[spans->count++] = (span_t){ .place = place, .first = offset, .end = offset + bytes };
		else
			spans->span[spans->count - 1].end = offset + bytes;
	}
	return (true);
}

/* A span, by the place it is in: the fixed registers, a cluster's instance, or the kept span. */
static erx_device_place_t
place_named(const erx_device_peripheral_t *peripheral, const span_t *span)
{
	erx_device_place_t named = { .kind = ERX_DEVICE_PLACE_FIXED, .first = span->first, .end = span->end };

	if (span->place == KEPT_PLACE) {
		named.kind = ERX_DEVICE_PLACE_KEPT;
	} else if (span->place != 0) {
		for (uint32_t at = 0; at < peripheral->base_count; at++) {
			const erx_device_base_t *const base = &peripheral->bases[at];

			if (span->place - 1 >= base->first && span->place - 1 - base->first < base->instances) {
				named.kind = ERX_DEVICE_PLACE_CLUSTER;
				named.base = at;
				named.instance = span->place - 1 - base->first;
			}
		}
	}
	return (named);
}

/*
 * Whether no two spans in different places share a byte, refused at the first two that do.
 * Within a place the generator keeps registers apart, and the gaps between them are free: a
 * controller may put one cluster in another's gap, as the VL805 puts its doorbells and runtime
 * registers between the operational registers and the ports. A device that reported bases
 * putting a register of one cluster over one of another, or over the fixed registers, would
 * give a register a driver may write the address of one the NIF owns.
 */
static bool
spans_apart(const erx_device_peripheral_t *peripheral, const spans_t *spans, erx_device_resolve_t *resolve)
{
	for (uint32_t a = 0; a < spans->count; a++) {
		for (uint32_t b = a + 1; b < spans->count; b++) {
			const span_t *const one = &spans->span[a], *const other = &spans->span[b];

			if (one->place != other->place && one->first < other->end && other->first < one->end) {
				refuse(resolve, (erx_device_refusal_t){ .rule = ERX_DEVICE_REFUSAL_OVERLAP,
				    .place = { place_named(peripheral, one), place_named(peripheral, other) } });
				return (false);
			}
		}
	}
	return (true);
}

/*
 * The walk's end: each capability cluster's registers have the instances found, every element
 * must fit the window, and no register may overlap one in another place or the kept span.
 */
static void
finish(const erx_device_peripheral_t *peripheral, erx_device_layout_t *layout, erx_device_resolve_t *resolve)
{
	spans_t spans = { .count = 0 };
	bool fits = true;

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
		fits = fits && elements_inside(peripheral, layout, reg, resolve, &spans);
	}
	if (resolve->kept_first < resolve->kept_end)
		spans.span[spans.count++] = (span_t){ .place = KEPT_PLACE, .first = resolve->kept_first, .end = resolve->kept_end };
	if (fits && spans_apart(peripheral, &spans, resolve))
		resolve->op = ERX_DEVICE_RESOLVE_DONE;
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
	if (resolve->entries == ERX_DEVICE_LIST_ENTRIES_MAX) {
		refuse(resolve, (erx_device_refusal_t){ .rule = ERX_DEVICE_REFUSAL_LIST_TOO_LONG });
		return;
	}
	if (resolve->size < LIST_WORD_BYTES || resolve->entry > resolve->size - LIST_WORD_BYTES) {
		refuse(resolve, (erx_device_refusal_t){ .rule = ERX_DEVICE_REFUSAL_ENTRY_PAST_WINDOW,
		    .offset_known = true, .offset = resolve->entry });
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

		/* advance asked for this entry only below ERX_DEVICE_LIST_ENTRIES_MAX entries. */
		resolve->entry_read[resolve->entries++] = (erx_device_entry_read_t){ .offset = resolve->entry,
		    .id = (uint8_t)(word & LIST_ID_MASK) };
		if (!take_entry(peripheral, layout, resolve, word & LIST_ID_MASK))
			return;
		resolve->entry = next == 0 ? 0 : resolve->entry + next * LIST_WORD_BYTES;
	}
	advance(peripheral, layout, resolve);
}
