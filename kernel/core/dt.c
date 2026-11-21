/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The device-tree reader (docs/design-device-tree.md, "The reader"). The
 * tree is untrusted input. erx_dt_accept hands the bytes to fdt_check_full
 * before anything else reads them, then walks the nodes once, refusing a
 * node deeper than ERX_DT_DEPTH_MAX and collecting the memory ranges. Every
 * later call takes the accepted view. Nothing here recurses or allocates:
 * walks keep the path from the root in a fixed array indexed by depth, and
 * the DMA walk carries at most ERX_DT_WINDOWS_MAX windows per level, so no
 * path is longer than the tree's length times those two bounds.
 *
 * libfdt is compiled with every check on (FDT_ASSUME_MASK 0), so no copy's
 * default decides which checks run; the guard below fails the build of a
 * reader compiled without it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <libfdt.h>

#include "erx/abi.h"
#include "erx/core/dt.h"

#if !defined(FDT_ASSUME_MASK) || FDT_ASSUME_MASK != 0
#error "erx_dt needs libfdt compiled with -DFDT_ASSUME_MASK=0"
#endif

/* The longest node path a row may name. */
#define DT_PATH_MAX	1024
/* The bytes of one cell. */
#define DT_CELL		4

/*
 * The PCI bus binding's three address cells, phys.hi, phys.mid and phys.lo
 * (PCI Bus Binding to IEEE Std 1275-1994, revision 2.1, section 2.2.1.1):
 * phys.hi is npt000ss bbbbbbbb dddddfff rrrrrrrr, its space code ss 1 for
 * I/O space, and phys.mid and phys.lo are the 64-bit PCI address. FreeBSD
 * reads a host bridge's ranges the same way (pci_host_generic_fdt.c:66-68,
 * :179-230).
 */
#define PCI_ADDRESS_CELLS	3
#define PCI_SPACE_SHIFT		24
#define PCI_SPACE_MASK		0x3
#define PCI_SPACE_CONFIGURATION	0x0
#define PCI_SPACE_IO		0x1
#define PCI_SPACE_MEMORY64	0x3
/* phys.hi's p bit: the region is prefetchable. */
#define PCI_PREFETCHABLE	(UINT32_C(1) << 30)

/*
 * A function's unit interrupt specifier on a PCI bus: its unit address,
 * phys.hi carrying its bus, device and function and the other two cells
 * zero, then its pin, INTA 1 to INTD 4, in the one cell of the bridge's
 * #interrupt-cells (PCI bus binding, sections 2.2.1.1 and 4.1.1,
 * "interrupts"; Devicetree Specification v0.4, section 2.4.4).
 */
#define PCI_BUS_SHIFT		16
#define PCI_DEVICE_SHIFT	11
#define PCI_FUNCTION_SHIFT	8
#define PCI_INTERRUPT_CELLS	1
#define PCI_INTX_CELLS		(PCI_ADDRESS_CELLS + PCI_INTERRUPT_CELLS)

/*
 * A walk over the nodes in document order. path[d] is the offset of the
 * node at depth d on the way from the root to the current node, so
 * path[depth - 1] is the current node's parent.
 */
typedef struct dt_walk {
	int	 offset;
	int	 depth;
	int	 path[ERX_DT_DEPTH_MAX + 1];
} dt_walk_t;

/*
 * One DMA window: bus addresses bus through last of the device, which at
 * the walk's current level are the addresses from at on. Invariant:
 * at + (last - bus) does not overflow.
 */
typedef struct dt_window {
	uint64_t	 bus;
	uint64_t	 last;
	uint64_t	 at;
} dt_window_t;

/* The address at the current level of the window's last bus address. */
static uint64_t
window_at_last(const dt_window_t *window)
{
	return (window->at + (window->last - window->bus));
}

/* A framebuffer format of the simple-framebuffer binding. */
typedef struct dt_format {
	const char	*name;
	uint32_t	 bits;
} dt_format_t;

/*
 * The binding's eleven format names, in its order, with their bits per
 * pixel (Linux 6.18 Documentation/devicetree/bindings/display/
 * simple-framebuffer.yaml:97-119, read through a clean-room facts record).
 */
static const dt_format_t dt_formats[] = {
	{ "a1r5g5b5", 16 }, { "a2r10g10b10", 32 }, { "a8b8g8r8", 32 }, { "a8r8g8b8", 32 },
	{ "r5g6b5", 16 }, { "r5g5b5a1", 16 }, { "r8g8b8", 24 }, { "x1r5g5b5", 16 },
	{ "x2r10g10b10", 32 }, { "x8r8g8b8", 32 }, { "x8b8g8r8", 32 }
};
#define DT_FORMATS	(sizeof(dt_formats) / sizeof(dt_formats[0]))

static void
walk_start(dt_walk_t *walk)
{
	walk->offset = 0;
	walk->depth = 0;
	walk->path[0] = 0;
}

/*
 * Moves to the next node. Returns false at the end of the tree, on a
 * libfdt error (walk->offset negative) and on a node deeper than
 * ERX_DT_DEPTH_MAX (walk->depth above it), which is never stored.
 */
static bool
walk_next(const void *fdt, dt_walk_t *walk)
{
	walk->offset = fdt_next_node(fdt, walk->offset, &walk->depth);
	if (walk->offset < 0 || walk->depth < 0 || walk->depth > ERX_DT_DEPTH_MAX)
		return (false);
	walk->path[walk->depth] = walk->offset;
	return (true);
}

/* A big-endian number of count cells, count 1 or 2, at at. */
static uint64_t
cells_read(const uint8_t *at, int count)
{
	uint64_t value;
	int i;

	value = 0;
	for (i = 0; i < count * DT_CELL; i++)
		value = value << 8 | at[i];
	return (value);
}

static bool
cells_valid(int count)
{
	return (count == 1 || count == 2);
}

static bool
prop_present(const void *fdt, int node, const char *name)
{
	return (fdt_getprop(fdt, node, name, NULL) != NULL);
}

/* Whether a property's value is exactly the string text. */
static bool
prop_is(const void *fdt, int node, const char *name, const char *text)
{
	const char *value;
	size_t length;
	int len;

	value = fdt_getprop(fdt, node, name, &len);
	length = strlen(text);
	return (value != NULL && len >= 0 && (size_t)len == length + 1 && memcmp(value, text, length + 1) == 0);
}

/* Whether a node's status is absent or "okay". */
static bool
node_enabled(const void *fdt, int node)
{
	return (!prop_present(fdt, node, "status") || prop_is(fdt, node, "status", "okay"));
}

/* Whether [first, last] meets any memory range of the view. */
static bool
memory_meets(const erx_dt_t *tree, uint64_t first, uint64_t last)
{
	uint32_t i;

	for (i = 0; i < tree->memory_count; i++)
		if (tree->memory[i].first <= last && first <= tree->memory[i].last)
			return (true);
	return (false);
}

/*
 * Adds the ranges of a memory node's reg, read with its parent's cell
 * counts. An empty range adds nothing: the firmware fills a memory node
 * that a board's tree leaves as zeros.
 */
static bool
memory_add(const void *fdt, int node, int parent, erx_dt_t *tree)
{
	const uint8_t *reg;
	uint64_t base, size;
	int ac, sc, entry, len, at;

	ac = fdt_address_cells(fdt, parent);
	sc = fdt_size_cells(fdt, parent);
	if (!cells_valid(ac) || !cells_valid(sc))
		return (false);
	reg = fdt_getprop(fdt, node, "reg", &len);
	if (reg == NULL)
		return (len == -FDT_ERR_NOTFOUND);
	entry = (ac + sc) * DT_CELL;
	if (len % entry != 0)
		return (false);
	for (at = 0; at < len; at += entry) {
		base = cells_read(reg + at, ac);
		size = cells_read(reg + at + ac * DT_CELL, sc);
		if (size == 0)
			continue;
		if (tree->memory_count == ERX_DT_MEMORY_MAX ||
		    __builtin_add_overflow(base, size - 1, &tree->memory[tree->memory_count].last))
			return (false);
		tree->memory[tree->memory_count++].first = base;
	}
	return (true);
}

const char *
erx_dt_accept(const void *bytes, size_t size, erx_dt_t *tree)
{
	dt_walk_t walk;

	memset(tree, 0, sizeof(*tree));
	/*
	 * fdt_check_header reads the strings block's size, the field a
	 * version 3 header adds, whatever the header's version, so a buffer
	 * shorter than the latest header is refused before libfdt reads it.
	 */
	if (bytes == NULL || size < FDT_V17_SIZE || fdt_check_full(bytes, size) != 0)
		return ("structure");

	walk_start(&walk);
	do {
		if (walk.depth == 1 && prop_is(bytes, walk.offset, "device_type", "memory") &&
		    node_enabled(bytes, walk.offset) &&
		    !memory_add(bytes, walk.offset, walk.path[walk.depth - 1], tree)) {
			memset(tree, 0, sizeof(*tree));
			return ("memory");
		}
	} while (walk_next(bytes, &walk));
	if (walk.depth > ERX_DT_DEPTH_MAX || (walk.offset < 0 && walk.offset != -FDT_ERR_NOTFOUND)) {
		memset(tree, 0, sizeof(*tree));
		return (walk.depth > ERX_DT_DEPTH_MAX ? "depth" : "structure");
	}
	tree->bytes = bytes;
	tree->size = size;
	return (NULL);
}

/* The offset of the node at path, an absolute path no longer than DT_PATH_MAX, or -1. */
static int
node_find(const erx_dt_t *tree, const char *path)
{
	size_t length;
	int node;

	if (tree->bytes == NULL || path == NULL || path[0] != '/')
		return (-1);
	length = strnlen(path, DT_PATH_MAX + 1);
	if (length > DT_PATH_MAX)
		return (-1);
	node = fdt_path_offset_namelen(tree->bytes, path, (int)length);
	return (node < 0 ? -1 : node);
}

/*
 * Fills path[0..depth] with the nodes from the root to node and returns
 * node's depth, or -1 if the walk does not reach it.
 */
static int
ancestry(const void *fdt, int node, int path[ERX_DT_DEPTH_MAX + 1])
{
	dt_walk_t walk;

	walk_start(&walk);
	do {
		if (walk.offset == node) {
			memcpy(path, walk.path, sizeof(walk.path));
			return (walk.depth);
		}
	} while (walk_next(fdt, &walk));
	return (-1);
}

/*
 * The node's coherence. The node's own dma-coherent or dma-noncoherent
 * decides, and must be empty. Both on the node, or a mark above it that
 * the node does not carry itself, give ERX_DT_DMA_COHERENCE: there the
 * readings of a mark on a bus disagree, and the specification defines the
 * mark only on a device. A mark above that repeats the node's own changes
 * no reading, as QEMU virt's dma-coherent on the root repeats each
 * device's.
 */
static erx_dt_dma_status_t
coherence_read(const void *fdt, const int path[ERX_DT_DEPTH_MAX + 1], int depth, bool *coherent)
{
	const void *on, *off;
	int on_len, off_len, i;

	on = fdt_getprop(fdt, path[depth], "dma-coherent", &on_len);
	off = fdt_getprop(fdt, path[depth], "dma-noncoherent", &off_len);
	if (on != NULL && off != NULL)
		return (ERX_DT_DMA_COHERENCE);
	if ((on != NULL && on_len != 0) || (off != NULL && off_len != 0))
		return (ERX_DT_DMA_MALFORMED);
	for (i = 0; i < depth; i++)
		if ((on == NULL && prop_present(fdt, path[i], "dma-coherent")) ||
		    (off == NULL && prop_present(fdt, path[i], "dma-noncoherent")))
			return (ERX_DT_DMA_COHERENCE);
	*coherent = on != NULL;
	return (ERX_DT_DMA_OK);
}

/*
 * Translates the windows in through one non-empty dma-ranges, entries of
 * ac bus address cells, pac parent address cells and sc length cells, into
 * out. The parts of a window no entry covers drop out. With pci, ac is the
 * PCI bus binding's three cells: an entry of I/O space is skipped, and the
 * bus address is the last two cells.
 */
static erx_dt_dma_status_t
windows_translate(const uint8_t *ranges, int len, int ac, int pac, int sc, bool pci, const dt_window_t *in,
    uint32_t in_count, dt_window_t out[ERX_DT_WINDOWS_MAX], uint32_t *out_count)
{
	const uint8_t *at;
	uint64_t child, parent, size, child_last, parent_last, window_last, low, high;
	uint32_t count, i;
	int entry, offset, child_cells;

	entry = (ac + pac + sc) * DT_CELL;
	if (len % entry != 0)
		return (ERX_DT_DMA_MALFORMED);
	child_cells = pci ? ac - 1 : ac;
	count = 0;
	for (offset = 0; offset < len; offset += entry) {
		at = ranges + offset;
		if (pci) {
			if ((cells_read(at, 1) >> PCI_SPACE_SHIFT & PCI_SPACE_MASK) == PCI_SPACE_IO)
				continue;
			at += DT_CELL;
		}
		child = cells_read(at, child_cells);
		parent = cells_read(at + child_cells * DT_CELL, pac);
		size = cells_read(at + (child_cells + pac) * DT_CELL, sc);
		if (size == 0)
			continue;
		if (__builtin_add_overflow(child, size - 1, &child_last) ||
		    __builtin_add_overflow(parent, size - 1, &parent_last))
			return (ERX_DT_DMA_MALFORMED);
		for (i = 0; i < in_count; i++) {
			window_last = window_at_last(&in[i]);
			low = in[i].at > child ? in[i].at : child;
			high = window_last < child_last ? window_last : child_last;
			if (low > high)
				continue;
			if (count == ERX_DT_WINDOWS_MAX)
				return (ERX_DT_DMA_RANGES);
			out[count].bus = in[i].bus + (low - in[i].at);
			out[count].last = in[i].bus + (high - in[i].at);
			out[count].at = parent + (low - child);
			count++;
		}
	}
	*out_count = count;
	return (ERX_DT_DMA_OK);
}

/*
 * Translates count windows, at path[level]'s bus addresses, up to the root
 * through each level's dma-ranges (docs/design-kernel.md, "DMA and the
 * IOMMU"), in place. A level's dma-ranges maps its own addresses, in its own
 * #address-cells and #size-cells, to its parent's, in the parent's
 * #address-cells. A level without the property passes the windows only
 * while no level above it has a non-empty one; the root, which has no
 * parent to map into, passes them only through no dma-ranges or an empty
 * one. With pci, path[level]'s own dma-ranges, and no other, may take the
 * PCI bus binding's three address cells, as a PCIe function's host bridge's
 * does.
 */
static erx_dt_dma_status_t
dma_walk(const erx_dt_t *tree, const int path[ERX_DT_DEPTH_MAX + 1], int level, bool pci,
    dt_window_t windows[ERX_DT_WINDOWS_MAX], uint32_t *count)
{
	dt_window_t next[ERX_DT_WINDOWS_MAX];
	const uint8_t *ranges;
	erx_dt_dma_status_t status;
	uint32_t translated;
	bool missing, three;
	int at, len, ac, sc, pac;

	missing = false;
	for (at = level; at >= 0; at--) {
		ranges = fdt_getprop(tree->bytes, path[at], "dma-ranges", &len);
		if (ranges == NULL) {
			if (len != -FDT_ERR_NOTFOUND)
				return (ERX_DT_DMA_MALFORMED);
			missing = true;
			continue;
		}
		if (len == 0)
			continue;
		if (missing || at == 0)
			return (ERX_DT_DMA_MALFORMED);
		ac = fdt_address_cells(tree->bytes, path[at]);
		sc = fdt_size_cells(tree->bytes, path[at]);
		pac = fdt_address_cells(tree->bytes, path[at - 1]);
		three = pci && at == level && ac == PCI_ADDRESS_CELLS;
		if ((!three && !cells_valid(ac)) || !cells_valid(sc) || !cells_valid(pac))
			return (ERX_DT_DMA_CELLS);
		status = windows_translate(ranges, len, ac, pac, sc, three, windows, *count, next, &translated);
		if (status != ERX_DT_DMA_OK)
			return (status);
		memcpy(windows, next, translated * sizeof(next[0]));
		*count = translated;
	}
	return (ERX_DT_DMA_OK);
}

/*
 * The walk of erx_dma_ranges (docs/design-kernel.md, "DMA and the IOMMU"):
 * every bus address of the bus at path[bus_level], through dma_walk up to the
 * root, then the RAM filter. When the bus is a PCIe function's host bridge,
 * its own level may take the PCI bus binding's three address cells. A
 * dma_limit other than 0 cuts each window's bus addresses below it, before
 * the RAM filter, so a window the device cannot reach drops out.
 */
static erx_dt_dma_status_t
range_read(const erx_dt_t *tree, const int path[ERX_DT_DEPTH_MAX + 1], int bus_level, erx_dt_row_t row,
    uint64_t dma_limit, erx_dt_device_t *facts)
{
	dt_window_t windows[ERX_DT_WINDOWS_MAX];
	const dt_window_t *found;
	erx_dt_dma_status_t status;
	uint32_t count, kept, i;

	windows[0] = (dt_window_t){ .bus = 0, .last = UINT64_MAX, .at = 0 };
	count = 1;
	status = dma_walk(tree, path, bus_level, row == ERX_DT_ROW_PCIE, windows, &count);
	if (status != ERX_DT_DMA_OK)
		return (status);

	found = NULL;
	kept = 0;
	for (i = 0; i < count; i++) {
		if (dma_limit != 0 && windows[i].bus >= dma_limit)
			continue;
		if (dma_limit != 0 && windows[i].last >= dma_limit)
			windows[i].last = dma_limit - 1;
		if (memory_meets(tree, windows[i].at, window_at_last(&windows[i]))) {
			found = &windows[i];
			kept++;
		}
	}
	if (kept != 1)
		return (ERX_DT_DMA_RANGES);
	facts->cpu = found->at;
	facts->bus = found->bus;
	facts->last = window_at_last(found);
	return (ERX_DT_DMA_OK);
}

/*
 * The first of mac-address, local-mac-address and address, in FreeBSD's
 * order, that holds six bytes, not all zero, with the group bit clear.
 */
static void
mac_read(const void *fdt, int node, erx_dt_device_t *facts)
{
	static const char *const names[] = { "mac-address", "local-mac-address", "address" };
	static const uint8_t zero[ERX_DT_MAC_BYTES];
	const uint8_t *value;
	size_t i;
	int len;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		value = fdt_getprop(fdt, node, names[i], &len);
		if (value == NULL || len != ERX_DT_MAC_BYTES || memcmp(value, zero, sizeof(zero)) == 0 ||
		    (value[0] & 1) != 0)
			continue;
		memcpy(facts->mac, value, ERX_DT_MAC_BYTES);
		facts->mac_status = ERX_DT_MAC_OK;
		return;
	}
}

void
erx_dt_device(const erx_dt_t *tree, const char *path, erx_dt_row_t row, uint64_t dma_limit, erx_dt_device_t *facts)
{
	int nodes[ERX_DT_DEPTH_MAX + 1];
	int node, depth, bus_level;

	memset(facts, 0, sizeof(*facts));
	facts->dma = ERX_DT_DMA_NO_NODE;
	facts->mac_status = ERX_DT_MAC_NONE;
	node = node_find(tree, path);
	if (node < 0)
		return;
	depth = ancestry(tree->bytes, node, nodes);
	if (depth < 0)
		return;
	mac_read(tree->bytes, node, facts);

	bus_level = row == ERX_DT_ROW_PCIE ? depth : depth - 1;
	if (bus_level < 0)
		facts->dma = ERX_DT_DMA_MALFORMED;
	else
		facts->dma = coherence_read(tree->bytes, nodes, depth, &facts->coherent);
	if (facts->dma == ERX_DT_DMA_OK)
		facts->dma = range_read(tree, nodes, bus_level, row, dma_limit, facts);
	if (facts->dma != ERX_DT_DMA_OK) {
		facts->coherent = false;
		facts->cpu = facts->bus = facts->last = 0;
	}
}

/* Whether a property is exactly one cell holding want. */
static bool
cell_is(const void *fdt, int node, const char *name, uint32_t want)
{
	const uint8_t *cell;
	int len;

	cell = fdt_getprop(fdt, node, name, &len);
	return (cell != NULL && len == DT_CELL && cells_read(cell, 1) == want);
}

/*
 * The cells of an interrupt-map entry's parent unit address: the interrupt
 * parent's #address-cells, 0 when it has none, as FreeBSD reads it
 * (ofw_bus_subr.c:428-430), or -1 for a value that is not one cell of at
 * most 2.
 */
static int
parent_unit_cells(const void *fdt, int parent)
{
	const uint8_t *cell;
	uint64_t count;
	int len;

	cell = fdt_getprop(fdt, parent, "#address-cells", &len);
	if (cell == NULL)
		return (len == -FDT_ERR_NOTFOUND ? 0 : -1);
	if (len != DT_CELL)
		return (-1);
	count = cells_read(cell, 1);
	return (count <= 2 ? (int)count : -1);
}

/*
 * The cells of the specifier of an interrupt controller whose binding the
 * architecture layer reads: its #interrupt-cells, 1 to
 * ERX_DT_INTERRUPT_CELLS_MAX, or 0 for a node that is no interrupt
 * controller, none of erx_dt_interrupt_controllers, or of another count.
 */
static uint32_t
controller_cells(const void *fdt, int parent)
{
	const char *const *compatible;
	const uint8_t *cell;
	uint64_t count;
	bool known;
	int len;

	known = false;
	for (compatible = erx_dt_interrupt_controllers; *compatible != NULL; compatible++)
		known = known || fdt_node_check_compatible(fdt, parent, *compatible) == 0;
	cell = fdt_getprop(fdt, parent, "#interrupt-cells", &len);
	if (!known || !prop_present(fdt, parent, "interrupt-controller") || cell == NULL || len != DT_CELL)
		return (0);
	count = cells_read(cell, 1);
	return (count <= ERX_DT_INTERRUPT_CELLS_MAX ? (uint32_t)count : 0);
}

/*
 * A place's unit interrupt specifier, ANDed with the bridge's
 * interrupt-map-mask, or false for a mask that is not one whole specifier.
 * Without a mask every bit counts.
 */
static bool
intx_key(const void *fdt, int node, const struct erx_pcie_place *place, uint32_t key[PCI_INTX_CELLS])
{
	const uint8_t *mask;
	int len, i;

	key[0] = (uint32_t)place->bus << PCI_BUS_SHIFT | (uint32_t)place->device << PCI_DEVICE_SHIFT |
	    (uint32_t)place->function << PCI_FUNCTION_SHIFT;
	key[1] = key[2] = 0;
	key[3] = place->pin;
	mask = fdt_getprop(fdt, node, "interrupt-map-mask", &len);
	if (mask == NULL)
		return (len == -FDT_ERR_NOTFOUND);
	if (len != PCI_INTX_CELLS * DT_CELL)
		return (false);
	for (i = 0; i < PCI_INTX_CELLS; i++)
		key[i] &= (uint32_t)cells_read(mask + i * DT_CELL, 1);
	return (true);
}

/* Whether an interrupt-map entry's child unit interrupt specifier is key. */
static bool
intx_matches(const uint8_t *entry, const uint32_t key[PCI_INTX_CELLS])
{
	int i;

	for (i = 0; i < PCI_INTX_CELLS; i++)
		if (cells_read(entry + i * DT_CELL, 1) != key[i])
			return (false);
	return (true);
}

/*
 * The walk over a host bridge's interrupt-map. An entry is its child unit
 * interrupt specifier (PCI_INTX_CELLS), its parent's phandle (one cell),
 * the parent's unit address and the parent's specifier. Every entry must
 * name the first entry's parent, so every entry has the first's length,
 * stride, and the walk is one pass; a map of at least one cell more than
 * the child specifier and a whole number of strides holds only whole
 * entries. The first matching entry decides; the controller's binding, in
 * the architecture layer, turns its specifier into a line.
 */
erx_dt_intx_status_t
erx_dt_intx(const erx_dt_t *tree, const char *path, const struct erx_pcie_place *place, uint32_t *line)
{
	const uint8_t *map, *entry, *found;
	uint32_t key[PCI_INTX_CELLS], cells[ERX_DT_INTERRUPT_CELLS_MAX], phandle, specifier_cells, i;
	int node, parent, len, unit_cells, stride, offset;

	*line = 0;
	node = node_find(tree, path);
	if (node < 0)
		return (ERX_DT_INTX_NO_NODE);
	map = fdt_getprop(tree->bytes, node, "interrupt-map", &len);
	if (map == NULL)
		return (len == -FDT_ERR_NOTFOUND ? ERX_DT_INTX_NONE : ERX_DT_INTX_MALFORMED);
	if (len == 0)
		return (ERX_DT_INTX_NONE);
	if (fdt_address_cells(tree->bytes, node) != PCI_ADDRESS_CELLS ||
	    !cell_is(tree->bytes, node, "#interrupt-cells", PCI_INTERRUPT_CELLS) ||
	    !intx_key(tree->bytes, node, place, key) || len < (PCI_INTX_CELLS + 1) * DT_CELL)
		return (ERX_DT_INTX_MALFORMED);

	phandle = (uint32_t)cells_read(map + PCI_INTX_CELLS * DT_CELL, 1);
	parent = fdt_node_offset_by_phandle(tree->bytes, phandle);
	if (parent < 0)
		return (ERX_DT_INTX_MALFORMED);
	specifier_cells = controller_cells(tree->bytes, parent);
	if (specifier_cells == 0)
		return (ERX_DT_INTX_UNSUPPORTED);
	unit_cells = parent_unit_cells(tree->bytes, parent);
	if (unit_cells < 0)
		return (ERX_DT_INTX_MALFORMED);
	stride = (PCI_INTX_CELLS + 1 + unit_cells + (int)specifier_cells) * DT_CELL;
	if (len % stride != 0)
		return (ERX_DT_INTX_MALFORMED);

	found = NULL;
	for (offset = 0; offset < len; offset += stride) {
		entry = map + offset;
		if (cells_read(entry + PCI_INTX_CELLS * DT_CELL, 1) != phandle)
			return (ERX_DT_INTX_UNSUPPORTED);
		if (found == NULL && intx_matches(entry, key))
			found = entry + (PCI_INTX_CELLS + 1 + unit_cells) * DT_CELL;
	}
	if (found == NULL)
		return (ERX_DT_INTX_NONE);
	for (i = 0; i < specifier_cells; i++)
		cells[i] = (uint32_t)cells_read(found + i * DT_CELL, 1);
	return (erx_dt_interrupt_line(cells, specifier_cells, line));
}

/* A property of one cell, nonzero. */
static bool
cell_read(const void *fdt, int node, const char *name, uint32_t *value)
{
	const uint8_t *cell;
	int len;

	cell = fdt_getprop(fdt, node, name, &len);
	if (cell == NULL || len != DT_CELL)
		return (false);
	*value = (uint32_t)cells_read(cell, 1);
	return (*value != 0);
}

/* The index of the node's format in dt_formats, or DT_FORMATS. */
static size_t
format_find(const void *fdt, int node)
{
	size_t i;

	for (i = 0; i < DT_FORMATS; i++)
		if (prop_is(fdt, node, "format", dt_formats[i].name))
			return (i);
	return (DT_FORMATS);
}

/*
 * Checks the one matching node, whose parent is parent, against the
 * binding and then against its authority: its pages must lie inside the
 * row's window and outside every memory range the tree reports.
 */
static erx_dt_fb_status_t
fb_read(const erx_dt_t *tree, int parent, int node, erx_dt_window_t window, erx_dt_framebuffer_t *fb)
{
	const void *fdt = tree->bytes;
	const uint8_t *reg;
	uint64_t base, length, last, first_page, last_page, window_last;
	uint32_t width, height, stride;
	size_t format;
	int ac, sc, len;

	if (prop_present(fdt, node, "memory-region"))
		return (ERX_DT_FB_UNSUPPORTED);
	ac = fdt_address_cells(fdt, parent);
	sc = fdt_size_cells(fdt, parent);
	if (!cells_valid(ac) || !cells_valid(sc))
		return (ERX_DT_FB_MALFORMED);
	reg = fdt_getprop(fdt, node, "reg", &len);
	if (reg == NULL || len != (ac + sc) * DT_CELL)
		return (ERX_DT_FB_MALFORMED);
	base = cells_read(reg, ac);
	length = cells_read(reg + ac * DT_CELL, sc);
	if (length == 0 || __builtin_add_overflow(base, length - 1, &last))
		return (ERX_DT_FB_MALFORMED);
	if (!cell_read(fdt, node, "width", &width) || !cell_read(fdt, node, "height", &height) ||
	    !cell_read(fdt, node, "stride", &stride) || (format = format_find(fdt, node)) == DT_FORMATS)
		return (ERX_DT_FB_MALFORMED);
	/* Each factor is below 2^32, so neither product overflows. */
	if ((uint64_t)width * (dt_formats[format].bits / 8) > stride || (uint64_t)stride * height > length)
		return (ERX_DT_FB_MALFORMED);

	fb->base = base;
	fb->length = length;
	first_page = base & ~(uint64_t)(ERX_PAGE_SIZE - 1);
	last_page = last | (ERX_PAGE_SIZE - 1);
	if (window.size == 0 || __builtin_add_overflow(window.base, window.size - 1, &window_last) ||
	    first_page < window.base || last_page > window_last || memory_meets(tree, first_page, last_page))
		return (ERX_DT_FB_OUTSIDE);
	fb->width = width;
	fb->height = height;
	fb->stride = stride;
	fb->format = (uint32_t)format;
	fb->bits_per_pixel = dt_formats[format].bits;
	return (ERX_DT_FB_OK);
}

void
erx_dt_framebuffer(const erx_dt_t *tree, const char *path, const char *compatible, erx_dt_window_t window,
    erx_dt_framebuffer_t *fb)
{
	erx_dt_fb_status_t status;
	int parent, node, match;

	memset(fb, 0, sizeof(*fb));
	fb->status = ERX_DT_FB_NONE;
	parent = node_find(tree, path);
	if (parent < 0 || compatible == NULL)
		return;
	match = -1;
	fdt_for_each_subnode(node, tree->bytes, parent) {
		if (!node_enabled(tree->bytes, node) || fdt_node_check_compatible(tree->bytes, node, compatible) != 0)
			continue;
		if (match >= 0) {
			fb->status = ERX_DT_FB_AMBIGUOUS;
			return;
		}
		match = node;
	}
	if (match < 0)
		return;
	status = fb_read(tree, parent, match, window, fb);
	if (status != ERX_DT_FB_OK && status != ERX_DT_FB_OUTSIDE)
		memset(fb, 0, sizeof(*fb));
	fb->status = status;
}

/*
 * Translates the window at path[depth]'s address level up to the root,
 * through each bus's ranges as windows_translate reads a dma-ranges: entries
 * of the bus's own address cells, its parent's address cells and its own size
 * cells. An empty ranges is the identity; a missing one maps nothing. Returns
 * the window's pieces at the root in out, or false on a malformed level.
 */
static bool
regs_translate(const void *fdt, const int path[ERX_DT_DEPTH_MAX + 1], int depth, dt_window_t out[ERX_DT_WINDOWS_MAX],
    uint32_t *count)
{
	dt_window_t windows[2][ERX_DT_WINDOWS_MAX];
	const uint8_t *ranges;
	int level, side, ac, pac, sc, len;

	windows[0][0] = out[0];
	side = 0;
	for (level = depth - 1; level > 0; level--) {
		ranges = fdt_getprop(fdt, path[level], "ranges", &len);
		if (ranges == NULL)
			return (false);
		if (len == 0)
			continue;
		ac = fdt_address_cells(fdt, path[level]);
		sc = fdt_size_cells(fdt, path[level]);
		pac = fdt_address_cells(fdt, path[level - 1]);
		if (!cells_valid(ac) || !cells_valid(sc) || !cells_valid(pac) ||
		    windows_translate(ranges, len, ac, pac, sc, false, windows[side], *count, windows[!side], count) !=
		    ERX_DT_DMA_OK)
			return (false);
		side = !side;
	}
	memcpy(out, windows[side], *count * sizeof(windows[side][0]));
	return (true);
}

/*
 * The CPU address of the range first through last at path[depth]'s address
 * level, a device's registers or a host bridge's window, first not above
 * last: false unless regs_translate takes it to the root whole, in one
 * piece and over none of the tree's RAM.
 */
static bool
range_to_cpu(const erx_dt_t *tree, const int path[ERX_DT_DEPTH_MAX + 1], int depth, uint64_t first, uint64_t last,
    uint64_t *cpu)
{
	dt_window_t pieces[ERX_DT_WINDOWS_MAX];
	uint32_t count;

	pieces[0] = (dt_window_t){ .bus = first, .last = last, .at = first };
	count = 1;
	if (!regs_translate(tree->bytes, path, depth, pieces, &count) || count != 1 || pieces[0].bus != first ||
	    pieces[0].last != last || memory_meets(tree, pieces[0].at, window_at_last(&pieces[0])))
		return (false);
	*cpu = pieces[0].at;
	return (true);
}

erx_dt_regs_status_t
erx_dt_registers(const erx_dt_t *tree, const char *path, const char *compatible, erx_dt_window_t window)
{
	const void *fdt = tree->bytes;
	int nodes[ERX_DT_DEPTH_MAX + 1];
	const uint8_t *reg;
	uint64_t base, size, last, cpu;
	int node, depth, ac, sc, len;

	node = node_find(tree, path);
	if (node < 0 || compatible == NULL || !node_enabled(fdt, node) ||
	    fdt_node_check_compatible(fdt, node, compatible) != 0)
		return (ERX_DT_REGS_NONE);
	depth = ancestry(fdt, node, nodes);
	if (depth < 1)
		return (ERX_DT_REGS_MALFORMED);
	ac = fdt_address_cells(fdt, nodes[depth - 1]);
	sc = fdt_size_cells(fdt, nodes[depth - 1]);
	if (!cells_valid(ac) || !cells_valid(sc))
		return (ERX_DT_REGS_MALFORMED);
	reg = fdt_getprop(fdt, node, "reg", &len);
	if (reg == NULL || len < (ac + sc) * DT_CELL)
		return (ERX_DT_REGS_MALFORMED);
	base = cells_read(reg, ac);
	size = cells_read(reg + ac * DT_CELL, sc);
	if (size == 0 || __builtin_add_overflow(base, size - 1, &last))
		return (ERX_DT_REGS_MALFORMED);
	if (!range_to_cpu(tree, nodes, depth, base, last, &cpu))
		return (ERX_DT_REGS_MALFORMED);
	/* The tree only confirms the row: a window anywhere else is another device's, or none's. */
	if (cpu != window.base || size != window.size)
		return (ERX_DT_REGS_OTHER);
	return (ERX_DT_REGS_OK);
}

/*
 * A host bridge's buses from its bus-range, two cells, the first bus and the
 * last (PCI bus binding, section 3.1.2), or every bus without one.
 */
static erx_dt_bridge_status_t
buses_read(const void *fdt, int node, uint8_t *bus_first, uint8_t *bus_last)
{
	const uint8_t *range;
	uint64_t first, last;
	int len;

	first = 0;
	last = UINT8_MAX;
	range = fdt_getprop(fdt, node, "bus-range", &len);
	if (range != NULL) {
		if (len != 2 * DT_CELL)
			return (ERX_DT_BRIDGE_MALFORMED);
		first = cells_read(range, 1);
		last = cells_read(range + DT_CELL, 1);
	} else if (len != -FDT_ERR_NOTFOUND) {
		return (ERX_DT_BRIDGE_MALFORMED);
	}
	if (first > last || last > UINT8_MAX)
		return (ERX_DT_BRIDGE_MALFORMED);
	*bus_first = (uint8_t)first;
	*bus_last = (uint8_t)last;
	return (ERX_DT_BRIDGE_OK);
}

/* A window's flags from its entry's phys.hi (PCI bus binding, section 2.2.1.1). */
static erx_pcie_window_flags_t
window_flags(uint32_t hi)
{
	erx_pcie_window_flags_t flags;

	flags = 0;
	if ((hi >> PCI_SPACE_SHIFT & PCI_SPACE_MASK) == PCI_SPACE_MEMORY64)
		flags |= ERX_PCIE_WINDOW_ADDR64;
	if ((hi & PCI_PREFETCHABLE) != 0)
		flags |= ERX_PCIE_WINDOW_PREFETCHABLE;
	return (flags);
}

/* Whether a window meets [first, last] in PCI space (pci) or in CPU space. */
static bool
window_meets(const erx_pcie_window_t *window, bool pci, uint64_t first, uint64_t last)
{
	uint64_t base;

	base = pci ? window->pci : window->cpu;
	return (base <= last && first <= base + (window->size - 1));
}

/*
 * The CPU address of the range first through last of path[depth]'s parent's
 * addresses, a host bridge's inbound window: false unless dma_walk takes it
 * to the root whole and in one piece. There is no RAM filter, since an
 * inbound window may reach device registers.
 */
static bool
dma_to_cpu(const erx_dt_t *tree, const int path[ERX_DT_DEPTH_MAX + 1], int depth, uint64_t first, uint64_t last,
    uint64_t *cpu)
{
	dt_window_t pieces[ERX_DT_WINDOWS_MAX];
	uint32_t count;

	pieces[0] = (dt_window_t){ .bus = first, .last = last, .at = first };
	count = 1;
	if (dma_walk(tree, path, depth - 1, false, pieces, &count) != ERX_DT_DMA_OK || count != 1 ||
	    pieces[0].bus != first || pieces[0].last != last)
		return (false);
	*cpu = pieces[0].at;
	return (true);
}

/*
 * A host bridge's memory windows from its ranges, or with inbound its
 * inbound windows from its dma-ranges, at path[depth], in entry order: each
 * entry the PCI bus binding's three cells, the parent's address in its
 * #address-cells and the size in the bridge's #size-cells
 * (pci_host_generic_fdt.c:179-230), the parent's range taken to the CPU's by
 * range_to_cpu, or for an inbound window by dma_to_cpu. An entry of I/O space
 * or of size 0 is skipped; one that meets an earlier window in PCI space is
 * malformed, and so is a window that meets an earlier one in CPU space, so a
 * BAR's PCI range has one CPU range. An empty dma-ranges maps every bus
 * address to the same CPU address, as none does, so it gives no inbound
 * window; an empty ranges maps nothing a three-cell address can name.
 */
static erx_dt_bridge_status_t
windows_read(const erx_dt_t *tree, const int path[ERX_DT_DEPTH_MAX + 1], int depth, bool inbound,
    erx_pcie_window_t windows[ERX_PCIE_WINDOWS_MAX])
{
	const void *fdt = tree->bytes;
	const uint8_t *ranges, *at;
	uint64_t pci, parent, size, pci_last, parent_last, cpu;
	uint32_t hi, space, count, i;
	int ac, sc, pac, entry, len, offset;
	bool translated;

	ranges = fdt_getprop(fdt, path[depth], inbound ? "dma-ranges" : "ranges", &len);
	if (ranges == NULL)
		return (len == -FDT_ERR_NOTFOUND ? ERX_DT_BRIDGE_OK : ERX_DT_BRIDGE_MALFORMED);
	if (len == 0)
		return (inbound ? ERX_DT_BRIDGE_OK : ERX_DT_BRIDGE_MALFORMED);
	ac = fdt_address_cells(fdt, path[depth]);
	sc = fdt_size_cells(fdt, path[depth]);
	pac = fdt_address_cells(fdt, path[depth - 1]);
	if (ac != PCI_ADDRESS_CELLS || !cells_valid(sc) || !cells_valid(pac))
		return (ERX_DT_BRIDGE_CELLS);
	entry = (ac + pac + sc) * DT_CELL;
	if (len % entry != 0)
		return (ERX_DT_BRIDGE_MALFORMED);
	count = 0;
	for (offset = 0; offset < len; offset += entry) {
		at = ranges + offset;
		hi = (uint32_t)cells_read(at, 1);
		space = hi >> PCI_SPACE_SHIFT & PCI_SPACE_MASK;
		pci = cells_read(at + DT_CELL, PCI_ADDRESS_CELLS - 1);
		parent = cells_read(at + PCI_ADDRESS_CELLS * DT_CELL, pac);
		size = cells_read(at + (PCI_ADDRESS_CELLS + pac) * DT_CELL, sc);
		if (space == PCI_SPACE_CONFIGURATION && !inbound)
			return (ERX_DT_BRIDGE_MALFORMED);
		if (space == PCI_SPACE_IO || size == 0)
			continue;
		if (__builtin_add_overflow(pci, size - 1, &pci_last) ||
		    __builtin_add_overflow(parent, size - 1, &parent_last))
			return (ERX_DT_BRIDGE_MALFORMED);
		if (count == ERX_PCIE_WINDOWS_MAX)
			return (ERX_DT_BRIDGE_RANGES);
		translated = inbound ? dma_to_cpu(tree, path, depth, parent, parent_last, &cpu) :
		    range_to_cpu(tree, path, depth, parent, parent_last, &cpu);
		if (!translated)
			return (ERX_DT_BRIDGE_MALFORMED);
		for (i = 0; i < count; i++)
			if (window_meets(&windows[i], true, pci, pci_last) ||
			    (!inbound && window_meets(&windows[i], false, cpu, cpu + (size - 1))))
				return (ERX_DT_BRIDGE_MALFORMED);
		windows[count++] = (erx_pcie_window_t){ .pci = pci, .cpu = cpu, .size = size, .flags = window_flags(hi) };
	}
	return (ERX_DT_BRIDGE_OK);
}

erx_dt_bridge_status_t
erx_dt_bridge(const erx_dt_t *tree, const char *path, erx_pcie_bridge_t *bridge)
{
	erx_pcie_window_t windows[ERX_PCIE_WINDOWS_MAX], inbound[ERX_PCIE_WINDOWS_MAX];
	int nodes[ERX_DT_DEPTH_MAX + 1];
	erx_dt_bridge_status_t status;
	uint8_t first, last;
	int node, depth;

	memset(windows, 0, sizeof(windows));
	memset(inbound, 0, sizeof(inbound));
	first = last = 0;
	depth = -1;
	node = node_find(tree, path);
	if (node >= 0)
		depth = ancestry(tree->bytes, node, nodes);
	if (depth < 0)
		status = ERX_DT_BRIDGE_NO_NODE;
	else if (depth == 0)
		status = ERX_DT_BRIDGE_MALFORMED;
	else
		status = buses_read(tree->bytes, node, &first, &last);
	if (status == ERX_DT_BRIDGE_OK)
		status = windows_read(tree, nodes, depth, false, windows);
	if (status == ERX_DT_BRIDGE_OK)
		status = windows_read(tree, nodes, depth, true, inbound);
	if (status != ERX_DT_BRIDGE_OK) {
		memset(windows, 0, sizeof(windows));
		memset(inbound, 0, sizeof(inbound));
		first = last = 0;
	}
	bridge->bus_first = first;
	bridge->bus_last = last;
	memcpy(bridge->windows, windows, sizeof(windows));
	memcpy(bridge->inbound, inbound, sizeof(inbound));
	return (status);
}

const char *
erx_dt_fb_format_name(uint32_t format)
{
	return (format < DT_FORMATS ? dt_formats[format].name : NULL);
}

/* Whether any of length bytes at bytes is not zero. */
static bool
any_set(const uint8_t *bytes, size_t length)
{
	for (size_t at = 0; at < length; at++)
		if (bytes[at] != 0)
			return (true);
	return (false);
}

void
erx_dt_seeds(const erx_dt_t *tree, erx_dt_seeds_t *seeds)
{
	static const char *const names[ERX_DT_SEEDS] = ERX_DT_SEED_NAMES;
	const void *value;
	size_t length;
	int chosen, len;

	_Static_assert(sizeof(names) / sizeof(names[0]) == ERX_DT_SEEDS, "every seed has its name");
	memset(seeds, 0, sizeof(*seeds));
	chosen = node_find(tree, "/chosen");
	if (chosen < 0)
		return;
	for (size_t seed = 0; seed < ERX_DT_SEEDS; seed++) {
		value = fdt_getprop(tree->bytes, chosen, names[seed], &len);
		if (value == NULL)
			continue;
		if (len <= 0)
			continue;
		/* Only the bytes the reader gives count: a zero prefix of a longer seed is absent. */
		length = (size_t)len < ERX_DT_SEED_MAX ? (size_t)len : ERX_DT_SEED_MAX;
		if (!any_set((const uint8_t *)value, length))
			continue;
		seeds->length[seed] = length;
		memcpy(seeds->bytes[seed], value, length);
	}
}
