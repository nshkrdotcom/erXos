/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's core over the sequencer (docs/design-device-dma.md, "The descriptor forms",
 * "The ledger", "Publication"; docs/design-usb.md, "What the DMA check judges"): what xHCI's rings
 * add to the check's rules. It reads no hardware and no shared memory, needs nothing of ERTS and
 * builds for the host, where its tests run.
 *
 * The form's memory is laid out once, by erx_device_trb_layout; erx_trb_form_layout derives the
 * ledger's tables and pools from that layout and no one else's, so a ring, a buffer and an input
 * context lie where the controller is told they do:
 *
 *   tables    a transfer ring per queue block, table b for block b, each needing a binding (its
 *             structure's mark in abi/formats) and placed as a ring; the command ring, which needs
 *             none; the event ring, which the device writes.
 *   pools     a pool per block, its buffers; and the command ring's, which holds just the input
 *             context, so a command's input-context name is a buffer of the command ring's pool,
 *             held while the command is in flight.
 *
 * A transfer reaches a ring only through the binding of its endpoint {slot, dci}, which the
 * ledger makes with its binding command's holding; a pair out of range names endpoint 0, which no
 * binding binds, so it reaches no ring. Its TRBs name only a buffer of that ring's pool, which the
 * check asks of every name, and the form takes the lowest no holding holds. Its tag is kept by the holding's head, the
 * TD's last TRB, which its completion names, since a control transfer without a data stage names
 * no buffer.
 */

#ifndef ERX_DEVICE_TRB_FORM_H
#define ERX_DEVICE_TRB_FORM_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx_device_ledger.h"
#include "erx_device_sequencer.h"
#include "erx_device_trb.h"

/*
 * One controller's rings. Its fields are the module's: callers read the ledger through
 * erx_trb_form_ledger and change the form only through the calls below. A tag is live while a
 * holding has its position as its head.
 */
typedef struct erx_trb_form {
	erx_dma_ledger_t	ledger;
	erx_device_trb_shape_t	shape;
	uint64_t		tags[ERX_DEVICE_TRB_BLOCKS_MAX][ERX_DEVICE_TRB_RING_TRBS];	/* by head */
} erx_trb_form_t;

/*
 * The ledger's layout of `trb`, into `layout`: tables and pools as the header says, each table's
 * stride its structure's record size, at the form's 64-bit device addresses. False for a ring of
 * more than ERX_DEVICE_TRB_RING_TRBS TRBs, past what the tags keep.
 */
bool	erx_trb_form_layout(const erx_device_trb_layout_t *trb, erx_dma_layout_t *layout);

/*
 * A form over `trb`, with no ring bound, its region entries naming the regions of `regions`
 * (erx_dma_ledger_make). False, writing nothing the caller may use, for a layout
 * erx_trb_form_layout or erx_dma_ledger_make refuses.
 */
bool	erx_trb_form_make(erx_trb_form_t *form, const erx_device_trb_layout_t *trb, const erx_dma_regions_t *regions);

const erx_dma_ledger_t	*erx_trb_form_ledger(const erx_trb_form_t *form);

/*
 * The ledger's endpoint of queue {slot, dci}: slot << 5 | dci, for a slot of 1..ERX_DEVICE_TRB_SLOTS_MAX
 * and a dci of 1..ERX_DEVICE_TRB_DCI_MAX, and 0, no endpoint, for any other pair.
 */
uint32_t	erx_trb_form_endpoint(uint32_t slot, uint32_t dci);

/*
 * Posts `request` under `tag` on queue {slot, dci} into `sequence`, which the effect layer applies
 * as erx_device_sequencer.h says; an out transfer's bytes go to sequence->fills[0]. The TRBs mirror
 * erx_device_trb_post's: a normal TRB, or a setup stage, a data stage when the request has one, and
 * a status stage. The refusals, in order:
 *   ERX_DEVICE_TRB_REFUSE_BADARG  no ring bound to the queue's endpoint, or a request
 *                                 erx_device_trb_request_valid refuses for the ring's block;
 *   ERX_DEVICE_TRB_REFUSE_FULL    no free buffer in the ring's pool, or too few free positions on
 *                                 the ring (the check's room rule);
 *   ERX_DEVICE_TRB_REFUSE_BADARG  any other verdict, a bug of this core.
 * Anything but ERX_DEVICE_TRB_ACCEPTED changes nothing.
 */
erx_device_trb_verdict_t	erx_trb_form_post(erx_trb_form_t *form, uint32_t slot, uint32_t dci,
				    const erx_device_trb_request_t *request, uint64_t tag, erx_dma_sequence_t *sequence);

/*
 * The tag of the transfer whose holding `found` is, as a query of the ledger found it, into `*tag`.
 * False for a holding no longer live (erx_dma_ledger_found_live), and for one of the command ring,
 * whose head is no transfer's.
 */
bool	erx_trb_form_tag(const erx_trb_form_t *form, erx_dma_found_t found, uint64_t *tag);

#endif /* ERX_DEVICE_TRB_FORM_H */
