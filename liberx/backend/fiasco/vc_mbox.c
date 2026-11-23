/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>

#include "erx/abi.h"
#include "erx/core/vc_mailbox.h"
#include "erx/core/vc_property.h"
#include "erx/hw/vc_mbox.h"
#include "erx/mmio.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/cache.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/vc_mbox.h"
#include "liberx/backend/fiasco/vm.h"

/* How long a request sleeps between reads of STATUS while the firmware has not answered. */
#define VC_MBOX_POLL_US	1000u

/* The mailbox's registers for the boot; length 0 while the root keeps none. */
static erx_mmio_t vc_mbox_device;

/*
 * The property buffer (docs/design-fiasco.md, "The firmware request"): a page of the root's
 * .bss, which bootstrap and sigma0 map at its physical address, so its address is the one the
 * firmware reads. It holds nothing else, and a page is larger than any cache writeback granule,
 * so no write of the root's shares a granule with what the firmware owns, and the clean and the
 * invalidate touch nothing but the buffer.
 */
static _Alignas(ERX_PAGE_SIZE) uint32_t vc_mbox_buffer[ERX_PAGE_SIZE / sizeof(uint32_t)];
_Static_assert(ERX_VC_BUFFER_WORDS * sizeof(uint32_t) <= sizeof(vc_mbox_buffer), "a request fits the buffer page");

/*
 * The mailbox core's state, under the mailbox lock of "Locks", which is taken for one step
 * of the core at a time and never across a sleep or a register access.
 */
static erx_vc_mailbox_t vc_mbox_state;
static erx_fiasco_lock_t vc_mbox_lock;


bool
erx_fiasco_vc_mbox_open(erx_dt_window_t window)
{
	const uint64_t offset = window.base & (ERX_PAGE_SIZE - 1);
	erx_mmio_t device;
	uintptr_t page;
	uint32_t word;

	vc_mbox_device = (erx_mmio_t){ .base = NULL, .length = 0 };
	if (erx_fiasco_vm_device_page(window.base - offset, &page) != ERX_OK)
		return (false);
	/* The registers lie in the window's first page: a window running past it is cut there. */
	device.base = (volatile uint8_t *)(page + offset);
	device.length = (size_t)(window.size < ERX_PAGE_SIZE - offset ? window.size : ERX_PAGE_SIZE - offset);
	/*
	 * A read of STATUS changes nothing. The accessors refuse a register past the window's
	 * length, so a window too short for STATUS fails here, and one too short for WRITE fails
	 * at that write, before anything is posted.
	 */
	if (!erx_vc_mbox_status_read(device, &word))
		return (false);
	vc_mbox_device = device;
	return (true);
}

bool
erx_fiasco_vc_mbox_kept(void)
{
	return (vc_mbox_device.length != 0);
}

/*
 * Reads the register op names (READ for READ, STATUS for READ_STATUS) and feeds it to the
 * core under the mailbox lock. A register the window does not hold, this one or the one the
 * step before wrote (reached false), ends the request as its deadline does: the core is fed
 * a clock past every deadline, and the mailbox is lost for the boot.
 */
static erx_vc_mailbox_step_t
vc_mbox_feed(erx_vc_mailbox_op_t op, bool reached)
{
	erx_vc_mailbox_step_t step;
	uint32_t word = 0;
	uint64_t now;

	reached = reached && (op == ERX_VC_MAILBOX_READ ? erx_vc_mbox_read_read(vc_mbox_device, &word) :
	    erx_vc_mbox_status_read(vc_mbox_device, &word));
	now = reached ? erx_fiasco_clock_ns() : UINT64_MAX;
	erx_fiasco_lock(&vc_mbox_lock);
	step = op == ERX_VC_MAILBOX_READ ? erx_vc_mailbox_read(&vc_mbox_state, word, now) :
	    erx_vc_mailbox_status(&vc_mbox_state, word, now);
	erx_fiasco_unlock(&vc_mbox_lock);
	return (step);
}

/*
 * The request routine of vc_mailbox.h, in the caller's thread: FILL and WRITE each go on to
 * read STATUS, and a STATUS that finds the request posted and unanswered sleeps before the
 * next.
 */
int
erx_firmware_request_row(erx_firmware_row_t row, uint8_t answer[ERX_VC_WINDOW_MAX], uint32_t *length)
{
	const erx_vc_tag_t *const spec = erx_vc_tag_of(row.tag);
	const l4_timeout_t poll = l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(VC_MBOX_POLL_US));
	uint32_t words[ERX_VC_BUFFER_WORDS];
	erx_vc_mailbox_step_t step;
	erx_vc_answer_t checked;

	*length = 0;
	for (uint32_t at = 0; at < ERX_VC_WINDOW_MAX; at++)
		answer[at] = 0;
	if (!erx_fiasco_vc_mbox_kept() || spec == NULL)
		return (ERX_ENOTSUP);
	erx_fiasco_lock(&vc_mbox_lock);
	step = erx_vc_mailbox_begin(&vc_mbox_state, (uintptr_t)vc_mbox_buffer, erx_fiasco_clock_ns());
	erx_fiasco_unlock(&vc_mbox_lock);
	while (step.op != ERX_VC_MAILBOX_DONE && step.op != ERX_VC_MAILBOX_CHECK) {
		switch (step.op) {
		case ERX_VC_MAILBOX_FILL:
			(void)erx_vc_request(spec, row.arguments, vc_mbox_buffer);
			erx_fiasco_cache_clean((uintptr_t)vc_mbox_buffer, sizeof(words));
			step = vc_mbox_feed(ERX_VC_MAILBOX_READ_STATUS, true);
			break;
		case ERX_VC_MAILBOX_WRITE:
			step = vc_mbox_feed(ERX_VC_MAILBOX_READ_STATUS,
			    erx_vc_mbox_write_write(vc_mbox_device, step.message));
			break;
		case ERX_VC_MAILBOX_READ:
			step = vc_mbox_feed(ERX_VC_MAILBOX_READ, true);
			break;
		case ERX_VC_MAILBOX_READ_STATUS:
		default:
			step = vc_mbox_feed(ERX_VC_MAILBOX_READ_STATUS, true);
			if (step.op == ERX_VC_MAILBOX_READ_STATUS)
				(void)l4_ipc_sleep(poll);
			break;
		}
	}
	if (step.op == ERX_VC_MAILBOX_DONE)
		return (step.status);
	/* The answer named the buffer: the firmware is done with it, and it is read once into words. */
	erx_fiasco_cache_clean_invalidate((uintptr_t)vc_mbox_buffer, sizeof(words));
	for (uint32_t at = 0; at < ERX_VC_BUFFER_WORDS; at++)
		words[at] = vc_mbox_buffer[at];
	erx_fiasco_lock(&vc_mbox_lock);
	checked = erx_vc_mailbox_answer(&vc_mbox_state, spec, words, answer);
	erx_fiasco_unlock(&vc_mbox_lock);
	*length = checked.length;
	return (checked.status);
}
