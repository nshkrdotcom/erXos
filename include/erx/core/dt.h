/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_DT_H
#define ERX_CORE_DT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The device-tree reader (docs/design-device-tree.md, "The reader"): a pure
 * function over a flattened device tree the firmware wrote, which is
 * untrusted input. erx_dt_accept checks the bytes whole and gives a view;
 * every later call takes the view, so no call reads a tree that was not
 * accepted. Every answer is a value, never a pointer into the tree.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* The deepest node accepted, the root being level 0. */
#define ERX_DT_DEPTH_MAX	16
/* The most memory ranges the memory nodes may give. */
#define ERX_DT_MEMORY_MAX	16
/* The most DMA windows a walk carries at one level. */
#define ERX_DT_WINDOWS_MAX	16
/* The bytes of a hardware (MAC) address. */
#define ERX_DT_MAC_BYTES	6
/* The most cells of an interrupt controller's specifier the reader takes. */
#define ERX_DT_INTERRUPT_CELLS_MAX	4

typedef struct erx_dt_memory erx_dt_memory_t;
typedef struct erx_dt erx_dt_t;
typedef struct erx_dt_device erx_dt_device_t;
typedef struct erx_dt_window erx_dt_window_t;
typedef struct erx_dt_framebuffer erx_dt_framebuffer_t;
typedef struct erx_dt_seeds erx_dt_seeds_t;

/* One range of RAM: first and last address, so no range overflows. */
struct erx_dt_memory {
	uint64_t	 first;
	uint64_t	 last;
};

/* An accepted tree: its bytes and the RAM its memory nodes report. Only
 * erx_dt_accept fills it; every other call trusts it. */
struct erx_dt {
	const void	*bytes;
	size_t		 size;
	uint32_t	 memory_count;
	erx_dt_memory_t	 memory[ERX_DT_MEMORY_MAX];
};

/* What a manifest row's path names. */
typedef enum erx_dt_row {
	/* A device's own node; its bus is the node's parent. */
	ERX_DT_ROW_NODE,
	/* A PCIe host bridge, standing for its function: it is node and bus. */
	ERX_DT_ROW_PCIE
} erx_dt_row_t;

typedef enum erx_dt_dma_status {
	ERX_DT_DMA_OK,
	ERX_DT_DMA_NO_NODE,
	ERX_DT_DMA_COHERENCE,
	ERX_DT_DMA_CELLS,
	ERX_DT_DMA_MALFORMED,
	ERX_DT_DMA_RANGES
} erx_dt_dma_status_t;

typedef enum erx_dt_mac_status {
	ERX_DT_MAC_OK,
	ERX_DT_MAC_NONE
} erx_dt_mac_status_t;

/*
 * A device's facts. coherent, cpu, bus and last mean something only when
 * dma is ERX_DT_DMA_OK, so a device never has a range without its
 * coherence; mac only when mac_status is ERX_DT_MAC_OK. The range is the
 * device's translation: the device sees CPU address cpu + x at bus address
 * bus + x, for every CPU address from cpu through last, inclusive.
 */
struct erx_dt_device {
	erx_dt_dma_status_t	 dma;
	bool			 coherent;
	uint64_t		 cpu;
	uint64_t		 bus;
	uint64_t		 last;
	erx_dt_mac_status_t	 mac_status;
	uint8_t			 mac[ERX_DT_MAC_BYTES];
};

/* A place below a closed bridge's root port, and a host bridge's record (abi/formats/pcie.txt). */
struct erx_pcie_place;
struct erx_pcie_bridge;

typedef enum erx_dt_bridge_status {
	ERX_DT_BRIDGE_OK,
	ERX_DT_BRIDGE_NO_NODE,
	ERX_DT_BRIDGE_CELLS,
	ERX_DT_BRIDGE_MALFORMED,
	ERX_DT_BRIDGE_RANGES
} erx_dt_bridge_status_t;

typedef enum erx_dt_intx_status {
	ERX_DT_INTX_OK,
	ERX_DT_INTX_NO_NODE,
	ERX_DT_INTX_NONE,
	ERX_DT_INTX_MALFORMED,
	ERX_DT_INTX_UNSUPPORTED
} erx_dt_intx_status_t;

/* A manifest row's window: the range of CPU addresses it admits. */
struct erx_dt_window {
	uint64_t	 base;
	uint64_t	 size;
};

typedef enum erx_dt_fb_status {
	ERX_DT_FB_OK,
	ERX_DT_FB_NONE,
	ERX_DT_FB_AMBIGUOUS,
	ERX_DT_FB_MALFORMED,
	ERX_DT_FB_UNSUPPORTED,
	ERX_DT_FB_OUTSIDE
} erx_dt_fb_status_t;

/*
 * A framebuffer's facts. base and length mean something on ERX_DT_FB_OK
 * and ERX_DT_FB_OUTSIDE, the rest on ERX_DT_FB_OK only. format indexes
 * the reader's table of the binding's names (erx_dt_fb_format_name).
 */
struct erx_dt_framebuffer {
	erx_dt_fb_status_t	 status;
	uint64_t		 base;
	uint64_t		 length;
	uint32_t		 width;
	uint32_t		 height;
	uint32_t		 stride;
	uint32_t		 format;
	uint32_t		 bits_per_pixel;
};

typedef enum erx_dt_regs_status {
	ERX_DT_REGS_OK,
	ERX_DT_REGS_NONE,
	ERX_DT_REGS_MALFORMED,
	ERX_DT_REGS_OTHER
} erx_dt_regs_status_t;

/*
 * The seeds /chosen may carry for a generator (docs/design-kernel.md,
 * "Entropy"), in the order one mixes them, and their property names in the
 * same order, for whoever names a seed.
 */
typedef enum erx_dt_seed {
	ERX_DT_SEED_RNG,
	ERX_DT_SEED_KASLR,
	ERX_DT_SEEDS
} erx_dt_seed_t;
#define ERX_DT_SEED_NAMES	{ "rng-seed", "kaslr-seed" }
/*
 * The most bytes of one seed the reader gives: one digest's input
 * (ERX_RNG_DIGEST_INPUT_MAX, which the seed core holds it to), so each seed
 * mixes as one part. A longer seed gives its first ERX_DT_SEED_MAX bytes.
 */
#define ERX_DT_SEED_MAX		1024

/*
 * /chosen's seeds: length[s] bytes of seed s in bytes[s], 0 for a seed the
 * tree does not carry. The bytes are secret; whoever holds them erases them.
 */
struct erx_dt_seeds {
	size_t		 length[ERX_DT_SEEDS];
	uint8_t		 bytes[ERX_DT_SEEDS][ERX_DT_SEED_MAX];
};

/*
 * Accepts size bytes at bytes as a tree, filling *tree. Returns NULL, or
 * the fixed reason "structure", "depth" or "memory".
 */
const char	*erx_dt_accept(const void *bytes, size_t size, erx_dt_t *tree);

/*
 * Fills *facts with the coherence, DMA range and hardware address of the
 * device at path, an absolute node path. dma_limit is a PCIe function's
 * row's DMA limit (docs/design-pcie.md, "DMA"), a device address,
 * exclusive, that cuts the range; 0 for none and for a device-tree row.
 */
void		 erx_dt_device(const erx_dt_t *tree, const char *path, erx_dt_row_t row, uint64_t dma_limit,
		    erx_dt_device_t *facts);

/*
 * The facts the tree holds of the PCI host bridge at path
 * (docs/design-device-tree.md, "A PCI host bridge"): fills bridge's
 * bus_first, bus_last and windows from its bus-range and ranges, the
 * windows in the order of their entries, the unused ones zero, and leaves
 * the rest of the record, which the manifest and the platform record give.
 * On any status but ERX_DT_BRIDGE_OK the buses and windows are zero.
 * ERX_DT_BRIDGE_NO_NODE: no node at path.
 * ERX_DT_BRIDGE_CELLS: a bridge with ranges whose #address-cells is not 3,
 * or whose #size-cells or parent's #address-cells is not 1 or 2.
 * ERX_DT_BRIDGE_MALFORMED: the root; an empty ranges or one not a whole
 * number of entries; an entry of configuration space, or whose PCI or
 * parent range wraps, is not translated to the CPU's whole and in one
 * piece, or meets the tree's RAM or an earlier window; a bus-range not two cells of at most
 * 255, the first not above the last.
 * ERX_DT_BRIDGE_RANGES: more than ERX_PCIE_WINDOWS_MAX memory windows.
 */
erx_dt_bridge_status_t erx_dt_bridge(const erx_dt_t *tree, const char *path, struct erx_pcie_bridge *bridge);

/*
 * The interrupt line the PCI host bridge at path routes for a closed bus's
 * place (docs/design-device-tree.md, "A PCI host bridge";
 * docs/design-pcie.md, "The closed bus"): the place's unit address and pin,
 * ANDed with the bridge's interrupt-map-mask, matched against each
 * interrupt-map entry in turn; the first match decides. The place comes
 * from the platform record, so it is a valid one: device below 32,
 * function below 8, pin 1 to 4, which the manifest reader proves. *line is the interrupt id the matching
 * entry names, and 0 on any status but ERX_DT_INTX_OK.
 * ERX_DT_INTX_NO_NODE: no node at path.
 * ERX_DT_INTX_NONE: no interrupt-map, or no entry for the place.
 * ERX_DT_INTX_MALFORMED: a bridge with a map whose #address-cells is not 3
 * or #interrupt-cells not 1, a mask or map not a whole number of entries,
 * an entry's parent that names no node or whose #address-cells is not one
 * cell of at most 2, or a specifier the controller's binding refuses as
 * malformed.
 * ERX_DT_INTX_UNSUPPORTED: a parent that is no interrupt controller the
 * binding reads (erx_dt_interrupt_controllers) of at most
 * ERX_DT_INTERRUPT_CELLS_MAX interrupt cells, an entry naming another
 * parent than the first's, or a matching entry whose line the binding does
 * not give an INTx line.
 */
erx_dt_intx_status_t erx_dt_intx(const erx_dt_t *tree, const char *path, const struct erx_pcie_place *place,
		    uint32_t *line);

/*
 * The architecture's half of erx_dt_intx (kernel/arch/<arch>/dt_interrupt.c).
 * erx_dt_interrupt_controllers: the compatible strings of the interrupt
 * controllers whose binding it reads, ending with NULL.
 * erx_dt_interrupt_line: the line a specifier of count cells names, when it
 * is one an INTx line may take, a level-triggered line of such a
 * controller. Sets *line on ERX_DT_INTX_OK only; ERX_DT_INTX_MALFORMED for
 * a specifier the binding does not allow, ERX_DT_INTX_UNSUPPORTED for one
 * it allows that is no such line. count is 1 to ERX_DT_INTERRUPT_CELLS_MAX.
 */
extern const char *const erx_dt_interrupt_controllers[];
erx_dt_intx_status_t erx_dt_interrupt_line(const uint32_t *cells, uint32_t count, uint32_t *line);

/* Fills *fb from the one enabled child of path whose compatible list holds
 * compatible, checked against window and the tree's RAM. */
void		 erx_dt_framebuffer(const erx_dt_t *tree, const char *path, const char *compatible,
		    erx_dt_window_t window, erx_dt_framebuffer_t *fb);

/*
 * Whether the tree places a device where its platform row says it is
 * (docs/design-device-tree.md, "Facts into records"): the node at path, an
 * absolute node path, enabled and with compatible in its compatible list,
 * has as its first register range, read with its parent's cell counts and
 * translated to CPU addresses through each bus's ranges up to the root
 * (docs/design-platforms.md, "The devices the kernel drives"), exactly the
 * row's window. The row is the one source of where the device is; the tree
 * only confirms it, so a caller maps window on ERX_DT_REGS_OK alone.
 * ERX_DT_REGS_NONE: no such node, or one disabled or of another compatible.
 * ERX_DT_REGS_MALFORMED: the range is empty, wraps, is not translated whole
 * and in one piece (a bus with no ranges translates nothing), or meets the
 * tree's RAM. ERX_DT_REGS_OTHER: a range other than window.
 */
erx_dt_regs_status_t erx_dt_registers(const erx_dt_t *tree, const char *path, const char *compatible,
		    erx_dt_window_t window);

/*
 * Fills *seeds from /chosen. A seed is absent when /chosen or its property
 * is missing or empty, or when every byte it would give is zero, as
 * erXos's kernel leaves it once it has used it.
 */
void		 erx_dt_seeds(const erx_dt_t *tree, erx_dt_seeds_t *seeds);

/* The name of a framebuffer format index, or NULL past the table. */
const char	*erx_dt_fb_format_name(uint32_t format);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_DT_H */
