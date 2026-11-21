/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_GROUP_H
#define ERX_FIASCO_GROUP_H

#include <stdint.h>

#include <stdbool.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * Groups as records and interrupts (docs/design-fiasco.md, "Budgets and groups as
 * records", "Interrupts and readiness"): the service's group records, and the root's
 * stubs of the group and IRQ calls. An IRQ object is an object record, which handles
 * name as they name every other.
 */

/* What erx_fiasco_group_admit gives for a thread that names no group. */
#define ERX_FIASCO_GROUP_NONE	UINT32_MAX

/*
 * Makes a group record with no home and returns its handle, from any task (the root's
 * stub in group.c, a task's in task_start.c). The root's first also starts the root's
 * dispatcher in it, which makes it the root's own group. parent is ignored: a recorded difference.
 */
int	erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group) ERX_WARN_UNUSED_RESULT;

/*
 * Writes up to max listed objects' labels, at most ERX_MSG_WORDS, into the caller's
 * public UTCB and returns how many, each object once however often it fired. Never
 * blocks. A worker is ERX_ETYPE. Local to the home task (park.c).
 */
int	erx_group_take_ready(uint32_t max) ERX_WARN_UNUSED_RESULT;

/* The service's group bodies. */
int	erx_fiasco_group_create_body(uint32_t task, uint64_t budget, uint64_t *group);
/*
 * erx_group_configure on a group the root did not take as its own: a handle that names
 * no group of task's is the lookup's refusal, an empty CPU set ERX_EINVAL; the grant is
 * otherwise accepted and not kept, since nothing in the Fiasco backend reads it.
 */
int	erx_fiasco_group_configure_body(uint32_t task, const erx_fiasco_group_configure_request_t *request);
/*
 * Before a thread's kernel objects: the record of the group a thread created in task by
 * caller joins, or ERX_FIASCO_GROUP_NONE for ERX_CAP_NULL, which names none. A group
 * homed in another task, or a homeless one while task is another group's home, is
 * ERX_ENOTSUP; a handle that names no group of the caller's, the lookup's refusal.
 */
int	erx_fiasco_group_admit(uint32_t caller, uint32_t task, uint64_t group, uint32_t *record);
/* Once the thread exists: makes task the home of what admit gave. */
void	erx_fiasco_group_join(uint32_t task, uint32_t record);
/*
 * Whether the record's home task has any thread; always so for the root. Such a group
 * outlives its handles and refuses its destroy, and goes with its home.
 */
bool	erx_fiasco_group_home_has_threads(uint32_t record);
/* The release of a record that ends: its binds go, and its home, if any, is a home no more. */
void	erx_fiasco_group_free(uint32_t record);
/* Names the task's dispatcher, one of its own threads, once; a second is ERX_EINVAL. */
int	erx_fiasco_dispatcher_set_body(uint32_t task, uint64_t thread);

/*
 * IRQ objects (docs/design-fiasco.md, "Interrupts and readiness"): kind is
 * ERX_IRQ_SOFT, a doorbell, which any task makes, ERX_IRQ_LINE with selector the line,
 * or ERX_IRQ_MSI with selector 0, the lowest free line of the manifest's MSI frame
 * (docs/design-pcie.md, "The MSI frame on Fiasco"), which only the root makes; resource
 * is ignored. An MSI's message is the frame's doorbell and the line's interrupt id, and
 * every other kind's is zero. A line the kernel will not attach, taken or not there, is
 * ERX_EBUSY; an object past the machine's ERX_FIASCO_IRQS_MAX, ERX_ENOMEM; an MSI when
 * every line of the frame has an object, ERX_ELIMIT; a task's line or MSI, or an MSI on
 * a platform without a frame, ERX_ENOTSUP; an MSI that names a selector, ERX_EINVAL.
 */
int	erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector,
	    uint64_t *irq, erx_msi_message_t *message) ERX_WARN_UNUSED_RESULT;
/*
 * Binds the object to the group, or ERX_CAP_SELF for the caller's home, with the label
 * its deliveries report; a line stays masked until the first ack after the bind. A bind waits until the group has a
 * home with a dispatcher. Binding a bound object to its group again moves its label; to
 * another group, ERX_ENOTSUP. A group's 65th object is ERX_ELIMIT. A group of ERX_CAP_NULL
 * unbinds it. A task other than the root names only the group it is the home of or a
 * group it created, as the target and as the group a bound object is in, and any other
 * is ERX_ETYPE.
 */
int	erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label) ERX_WARN_UNUSED_RESULT;
/*
 * From any task holding the object. On a bound object, the first ack after the bind lets a line deliver, and each later
 * one lets it deliver again after a delivery; an ack on an unbound object opens nothing, so a driver binds before its
 * first ack, which differs from erXos's kernel, where it unmasks.
 */
int	erx_irq_ack(uint64_t irq) ERX_WARN_UNUSED_RESULT;
int	erx_irq_trigger(uint64_t irq) ERX_WARN_UNUSED_RESULT;

/*
 * The calls' bodies, on the service, for the calling task. A create's reply carries the
 * object in its first word and the message's address and data in its second and third
 * (abi/erx_abi.txt, erx_fiasco_irq_create_request).
 */
int	erx_fiasco_irq_create_body(uint32_t task, const erx_fiasco_irq_create_request_t *request,
	    erx_fiasco_reply_t *reply);
int	erx_fiasco_irq_bind_body(uint32_t task, const erx_fiasco_irq_bind_request_t *request);
int	erx_fiasco_irq_unbind_body(uint32_t task, uint64_t irq);
/*
 * The one placement of an IRQ capability in a holder (docs/design-fiasco.md, "Handles"),
 * which every create, duplicate and pass of an IRQ entry ends in: the record's object goes
 * to the IRQ slot of the new entry, handle, in task's object space, with Fiasco's read right
 * alone, when the entry's rights hold ERX_HR_TRIGGER or ERX_HR_ACK, and nothing goes there
 * otherwise. ERX_ENOMEM when Fiasco does not map it.
 */
int	erx_fiasco_irq_place(uint32_t task, uint32_t record, uint64_t handle, uint32_t rights) ERX_WARN_UNUSED_RESULT;
/* Empties the IRQ slot of task's entry handle, at its close. */
void	erx_fiasco_irq_unplace(uint32_t task, uint64_t handle);
#ifdef ERX_FIASCO_TEST_HOOKS
/* Places at Fiasco's last object-space slot and past it (irq.c); NULL, or the failure line. */
const char	*erx_fiasco_test_object_space_probe(uint64_t irq);
#endif
/*
 * Takes the manifest's MSI frame for ERX_IRQ_MSI's lines, at the root's boot before any
 * create; false for a frame of lines but no base, lines past msi_frame_lines_max or a
 * doorbell whose address wraps. Until then, and for a frame of no lines, an MSI is
 * ERX_ENOTSUP.
 */
bool	erx_fiasco_irq_msi_frame(const erx_mf_msi_frame_t *frame) ERX_WARN_UNUSED_RESULT;
/* What an IRQ record's end gives back: its bind goes, then its kernel object. */
void	erx_fiasco_irq_free(uint32_t record);
/* Makes every waiting bind to the group record once its home and the home's dispatcher both exist. */
void	erx_fiasco_irq_group_ready(uint32_t record);
/* A group's end: every bind to it goes, so its objects stay, unbound. */
void	erx_fiasco_irq_group_end(uint32_t record);

#endif /* ERX_FIASCO_GROUP_H */
