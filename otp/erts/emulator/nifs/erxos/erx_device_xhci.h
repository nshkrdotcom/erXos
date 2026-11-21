/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The device NIF's calls on an xHCI controller beside erx_device.h's, apart from it because they
 * speak the TRB form's types (erx_device_trb_form.h), whose ledger needs erx_device.h first.
 */

#ifndef ERX_DEVICE_XHCI_H
#define ERX_DEVICE_XHCI_H

#include <stdint.h>

#include "erx_device.h"
#include "erx_device_trb_form.h"

/*
 * The TRB ring form's calls on an xHCI controller (docs/design-usb.md, "The TRB ring form"), which
 * erx_device:post/4, complete/2 and queue_state/2 take on such a device, once negotiate has
 * started it. Each returns ERX_EINVAL for a device that is not an xHCI controller or that no
 * negotiate call has made a record for, and ERX_ECORRUPT for one not started since its open or
 * since its last negotiation began, or whose form an event broke ({error, broken}), until a
 * negotiation starts it again; otherwise ERX_OK, with the call's own answer.
 *
 * A transfer's post, `request` under `tag` on queue {slot, dci}, and a command's, `command` under
 * `tag`, each give the form's verdict (erx_trb_form_post, erx_trb_form_command): accepted, its TRBs
 * written and its doorbell rung, slot's with target dci for a transfer and doorbell 0 with target 0
 * for a command; or refused, badarg, full or halted, with nothing written.
 */
int	erx_device_trb_post(const erx_device_t *device, uint32_t slot, uint32_t dci, uint64_t tag,
	    const erx_device_trb_request_t *request, erx_device_trb_verdict_t *verdict);
int	erx_device_trb_command(const erx_device_t *device, const erx_trb_command_t *command, uint64_t tag,
	    erx_device_trb_verdict_t *verdict);

/*
 * What a completion's caller gives for each answer, in order: where `answer->data.length` bytes go,
 * a transfer's bytes moved, never NULL when that is not 0; ignored when it is 0, a command's, a
 * port's or a `stopped` answer.
 */
typedef uint8_t	*erx_device_trb_sink_t(void *context, const erx_trb_answer_t *answer);

/*
 * Completes the events the controller has written, at most ERX_DEVICE_COMPLETE_ENTRIES: each
 * answer goes to `sink` in the core's order (erx_trb_form_complete), a retired ring's `stopped`
 * answers before the command's own; before them ERDP is written past every event the core consumed,
 * with its busy bit cleared, on every call that reaches the core. ERX_OK with how many answers, those before an event that broke the form
 * included; ERX_ECORRUPT, with none, as above.
 */
int	erx_device_trb_complete(const erx_device_t *device, erx_device_trb_sink_t *sink, void *context,
	    uint32_t *answered);

/* Queue {slot, dci}'s state from the form's own record (erx_trb_form_queue_state); NONE names no queue. */
int	erx_device_trb_queue_state(const erx_device_t *device, uint32_t slot, uint32_t dci,
	    erx_trb_queue_state_t *state);

#endif /* ERX_DEVICE_XHCI_H */
