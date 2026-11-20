/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DEVICE_TRB_MODEL_H
#define ERX_DEVICE_TRB_MODEL_H

/*
 * A model of an xHCI controller's ring side: the device that erx_device_trb.c's plans drive
 * (docs/design-usb.md, "The TRB ring form", Verification). It takes a TRB the moment its cycle
 * bit matches its consumer cycle state on a running ring, doorbell or not (4.9.2, p. 170),
 * follows link TRBs and toggles its cycle where they say, reads an out buffer and writes an in
 * buffer as it takes the TRB that names it, and starts each transfer ring where an input
 * context's endpoint context or a Set TR Dequeue Pointer command points. It reaches memory only
 * through device addresses and the caller's accessor, so a wrong address or a TRB published
 * before its bytes shows as a refused TRB or a wrong byte.
 *
 * It keeps no event ring: each completion it would report is appended to `events` for the
 * caller to drain. It reads no ERTS, liberx or global state, so it builds for the host anywhere.
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

/* The out bytes of a TRB the controller took, as it read them from the buffer at `addr`. */
typedef void	erx_device_trb_model_sink_t(void *context, uint32_t slot, uint32_t dci, uint64_t addr,
		    const uint8_t *bytes, uint32_t length);

typedef enum erx_device_trb_model_event_kind {
	ERX_DEVICE_TRB_MODEL_TRANSFER,
	ERX_DEVICE_TRB_MODEL_COMMAND,
} erx_device_trb_model_event_kind_t;

/*
 * A completion: a transfer's, with the TRB that completed it, the bytes an in transfer's
 * buffer received (`length` bytes of the pattern `pattern` draws) and its code; or a command's,
 * with its TRB, code and slot.
 */
typedef struct erx_device_trb_model_event {
	erx_device_trb_model_event_kind_t	kind;
	uint32_t				slot;
	uint32_t				dci;
	uint64_t				pointer;
	uint32_t				code;
	uint32_t				length;
	uint32_t				pattern;
} erx_device_trb_model_event_t;

#define ERX_DEVICE_TRB_MODEL_EVENTS	64u

typedef struct erx_device_trb_model_ring {
	bool		running;
	bool		halted;
	bool		fail;		/* the next TD it completes ends with a transaction error */
	uint64_t	dequeue;	/* the device address of the next TRB */
	uint32_t	cycle;
	uint32_t	in_length;	/* the bytes the current control transfer's data stage received */
	uint32_t	in_pattern;
} erx_device_trb_model_ring_t;

typedef struct erx_device_trb_model {
	const erx_device_trb_layout_t	*layout;
	erx_device_trb_memory_t		memory;
	erx_device_trb_model_sink_t	*sink;
	void				*sink_context;
	bool				enabled[ERX_DEVICE_TRB_SLOTS_MAX + 1];
	erx_device_trb_model_ring_t	command;
	erx_device_trb_model_ring_t	rings[ERX_DEVICE_TRB_SLOTS_MAX + 1][ERX_XHCI_DEVICE_CONTEXTS];
	uint32_t			patterns;	/* the next in pattern */
	uint8_t				scratch[ERX_DEVICE_BUFFER_MAX];	/* an out buffer as read */
	uint32_t			event_count;
	erx_device_trb_model_event_t	events[ERX_DEVICE_TRB_MODEL_EVENTS];
} erx_device_trb_model_t;

/* Byte `index` of in pattern `pattern`, which the model writes and its caller checks. */
static inline uint8_t
erx_device_trb_model_pattern(uint32_t pattern, uint32_t index)
{
	return ((uint8_t)(pattern * 131u + index * 7u + 1u));
}

/* A model after its install: every slot disabled, the command ring at its base with cycle 1. */
void	erx_device_trb_model_init(erx_device_trb_model_t *model, const erx_device_trb_layout_t *layout,
	    const erx_device_trb_memory_t *memory, erx_device_trb_model_sink_t *sink, void *sink_context);

/* A doorbell store: 0 for the command ring, otherwise the slot's, its value the endpoint's index. */
void	erx_device_trb_model_doorbell(erx_device_trb_model_t *model, uint32_t doorbell, uint32_t target);

/*
 * The controller runs: the command ring, then every running transfer ring, each as far as the
 * cycle bits allow. ERX_OK, or ERX_ECORRUPT for a TRB it cannot take (an unknown type, an
 * address outside memory, a context it cannot read) or a full event list.
 */
int	erx_device_trb_model_run(erx_device_trb_model_t *model);

#endif /* ERX_DEVICE_TRB_MODEL_H */
