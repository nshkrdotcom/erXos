/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DEVICE_TRB_MODEL_H
#define ERX_DEVICE_TRB_MODEL_H

/*
 * A model of an xHCI controller's ring side: the device that the TRB ring form's sequences drive
 * (erx_device_trb_form.h; docs/design-usb.md, "The TRB ring form", Verification). It takes a TRB
 * the moment its cycle bit matches its consumer cycle state on a running ring, doorbell or not
 * (4.9.2, p. 170), follows link TRBs and toggles its cycle where they say, reads an out buffer
 * and writes an in buffer as it takes the TRB that names it, and starts each transfer ring where
 * an input context's endpoint context or a Set TR Dequeue Pointer command points. It reaches
 * memory only through device addresses and the caller's accessor, so a wrong address or a TRB
 * published before its bytes shows as a refused TRB or a wrong byte.
 *
 * It reports as the controller does, into the event ring the segment table names (6.5): each
 * Transfer Event and Command Completion Event (6.4.2.1, 6.4.2.2) is written whole through the
 * accessor at the enqueue position with the producer cycle state, which toggles where the
 * segment ends, so its caller acquires events by their cycle bits as the form
 * does. The caller's event ring dequeue register writes tell it how far the events are
 * consumed; an event with no room is a fault: the ring full. It reads no ERTS, liberx
 * or global state, so it builds for the host anywhere.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx_device_trb.h"

/* Device memory by device address; each false, copying nothing, outside it. */
typedef struct erx_device_trb_memory {
	void	*context;
	bool	(*read)(void *context, uint64_t addr, uint8_t *bytes, uint32_t length);
	bool	(*write)(void *context, uint64_t addr, const uint8_t *bytes, uint32_t length);
} erx_device_trb_memory_t;

/*
 * A buffer the controller moved as it took the TRB naming it at `addr`: an out buffer's bytes as
 * it read them, or, `in`, the bytes it wrote into an in buffer.
 */
typedef void	erx_device_trb_model_sink_t(void *context, uint32_t slot, uint32_t dci, uint64_t addr,
		    const uint8_t *bytes, uint32_t length, bool in);

typedef struct erx_device_trb_model_ring {
	bool		running;
	bool		halted;
	bool		fail;		/* the next TD it completes ends with a transaction error */
	bool		short_packet;	/* the next in TRB moving bytes moves half of them, a short packet */
	bool		in_td;		/* it has taken a TD's first TRB and not its last */
	uint64_t	dequeue;	/* the device address of the next TRB */
	uint32_t	cycle;
} erx_device_trb_model_ring_t;

typedef struct erx_device_trb_model {
	const erx_device_trb_layout_t	*layout;
	erx_device_trb_memory_t		memory;
	erx_device_trb_model_sink_t	*sink;
	void				*sink_context;
	bool				enabled[ERX_DEVICE_TRB_SLOTS_MAX + 1];
	bool				addressed[ERX_DEVICE_TRB_SLOTS_MAX + 1];	/* its device context taken */
	erx_device_trb_model_ring_t	command;
	erx_device_trb_model_ring_t	rings[ERX_DEVICE_TRB_SLOTS_MAX + 1][ERX_XHCI_DEVICE_CONTEXTS];
	uint32_t			patterns;	/* the next in pattern */
	uint8_t				scratch[ERX_DEVICE_BUFFER_MAX];	/* a buffer as moved */
	/* the event ring, from the segment table's one entry */
	uint64_t			event_base;
	uint32_t			event_trbs;
	uint32_t			event_enqueue;	/* the producer's index */
	uint32_t			event_cycle;	/* the producer cycle state */
	uint32_t			event_dequeue;	/* the index the dequeue register names */
} erx_device_trb_model_t;

/* Byte `index` of in pattern `pattern`, which the model writes and its caller checks. */
static inline uint8_t
erx_device_trb_model_pattern(uint32_t pattern, uint32_t index)
{
	return ((uint8_t)(pattern * 131u + index * 7u + 1u));
}

/* A model after its install: every slot disabled, the command ring at its base with cycle 1, no event ring. */
void	erx_device_trb_model_init(erx_device_trb_model_t *model, const erx_device_trb_layout_t *layout,
	    const erx_device_trb_memory_t *memory, erx_device_trb_model_sink_t *sink, void *sink_context);

/*
 * The event ring segment table's base register written: the controller reads the
 * table's one entry, the segment's address and size, and produces from the segment's first TRB
 * with cycle 1. False for an entry it cannot read, a size of 0, or a segment outside memory.
 */
bool	erx_device_trb_model_segment_table(erx_device_trb_model_t *model, uint64_t table);

/* The event ring dequeue register written: `dequeue`, a device address in the segment. False for one outside it. */
bool	erx_device_trb_model_dequeue(erx_device_trb_model_t *model, uint64_t dequeue);

/* A doorbell store: 0 for the command ring, otherwise the slot's, its value the endpoint's index. */
void	erx_device_trb_model_doorbell(erx_device_trb_model_t *model, uint32_t doorbell, uint32_t target);

/*
 * The controller runs: the command ring, then every running transfer ring, each as far as the
 * cycle bits allow. ERX_OK, or ERX_ECORRUPT for a TRB it cannot take (an unknown type, an
 * address outside memory, a context it cannot read) or an event with no room in the event ring.
 */
int	erx_device_trb_model_run(erx_device_trb_model_t *model);

#endif /* ERX_DEVICE_TRB_MODEL_H */
