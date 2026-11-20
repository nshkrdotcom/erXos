/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The IRQ calls' bodies, on the service, which alone touches this table
 * (docs/design-fiasco.md, "Interrupts and readiness"). An IRQ object is an object
 * record of kind IRQ, any task's to make as a doorbell and the root's alone as a line or an MSI,
 * and any holder's to bind; its kernel object sits in one of the root's slots, kept here
 * with its bind. A holder triggers and acks it itself, on the capability erx_fiasco_irq_place
 * put at its entry's IRQ slot, with no request (docs/design-fiasco.md, "Handles"). The root binds
 * into any group it holds, as the domain library binds a domain's bell, and the root's own
 * drivers their lines; another holder binds only within the group it is the home of or
 * a group it created (irq_group_allowed).
 *
 * A bind gives the object a free entry of its group, one of the 64 the group's home
 * task has labels for, stores the caller's label on the home's label page through the
 * window, and only then binds the object to the home's dispatcher with the entry as
 * Fiasco's label, so a delivery never reaches an entry before its label. Until the
 * group has a home with a dispatcher the bind waits, and group.c makes it once both
 * exist; a software fire before then arrives at the bind, as Fiasco keeps it for a
 * detached object. A bind goes with its group, whose end detaches the object. A bound
 * line stays masked until the holder's first ack after the bind (docs/design-kernel.md,
 * "IRQ objects"), and from each delivery until its ack, which is Fiasco's own behaviour
 * for a level interrupt. The ack is the holder's own unmask, so one made while the bind
 * waits reaches an object with no receiver and opens nothing the make keeps.
 *
 * An MSI object is a line of the manifest's MSI frame, the lowest that no object holds
 * (msi_lines.c), set edge-triggered and bound as a line is; its create answers the
 * frame's doorbell and the line's interrupt id (docs/design-pcie.md, "The MSI frame on
 * Fiasco").
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/icu.h>
#include <l4/sys/irq.h>
#include <l4/sys/rcv_endpoint.h>
#include <l4/sys/task.h>

#include "liberx/backend/core/handles.h"
#include "liberx/backend/core/park_table.h"
#include "liberx/backend/core/vm_table.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/msi_lines.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

/* What a slot's group holds while the object is bound to none. */
#define IRQ_UNBOUND	0u
/*
 * The MSI frame's doorbell, the register a function writes the line's interrupt id to,
 * at this offset from the frame's base (docs/design-platforms.md, "MSI frames").
 */
#define IRQ_MSI_DOORBELL	UINT64_C(0x40)

/* One kernel object, what it fires from, and its bind. */
typedef struct irq_object {
	uint32_t	record;	/* the object record's index plus one, 0 for a free slot */
	uint32_t	kind;	/* ERX_IRQ_SOFT, ERX_IRQ_LINE or ERX_IRQ_MSI */
	uint32_t	line;	/* a line's or an MSI's interrupt id, 0 for a software object */
	uint32_t	group;	/* the group record's index plus one, or IRQ_UNBOUND */
	uint32_t	entry;	/* its entry in the group, while bound */
	bool		made;	/* bound to the home's dispatcher, not waiting */
	uint64_t	label;	/* the caller's, which the home's label page holds once made */
} irq_object_t;

static irq_object_t irq_objects[ERX_FIASCO_IRQS_MAX];
/* The manifest's MSI frame: its lines and its doorbell, no lines until the root sets it. */
static erx_fiasco_msi_range_t irq_msi_range;
static uint64_t irq_msi_doorbell;

static l4_cap_idx_t
irq_cap(const irq_object_t *object)
{
	return ((l4_cap_idx_t)erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_IRQS + (uint32_t)(object - irq_objects)));
}

/* The slot an IRQ record's object is in: every live IRQ record has one. */
static irq_object_t *
irq_of(uint32_t record)
{
	for (uint32_t slot = 0; slot < ERX_FIASCO_IRQS_MAX; slot++)
		if (irq_objects[slot].record == record + 1)
			return (&irq_objects[slot]);
	return (NULL);
}

/* The object a task's handle names, or the lookup's refusal. */
static int
irq_named(uint32_t task, uint64_t irq, irq_object_t **object)
{
	uint32_t record;
	const int status = erx_fiasco_object_find(task, irq, ERX_BACKEND_OBJECT_IRQ, &record);

	if (status != ERX_OK)
		return (status);
	*object = irq_of(record);
	return (*object != NULL ? ERX_OK : ERX_ESTALE);
}

/*
 * Stores label as the entry's on the home task's label page, through the window, with
 * release order; ERX_EINVAL when the task has given up the page.
 */
static int
irq_label_store(uint32_t home, uint32_t entry, uint64_t label)
{
	const uint64_t addr = (uint64_t)(uintptr_t)&erx_fiasco_labels()[entry];
	const uintptr_t window = erx_fiasco_vm_task_window(home, addr & ~ERX_BACKEND_VM_PAGE_MASK);

	if (window == 0)
		return (ERX_EINVAL);
	atomic_store_explicit((_Atomic uint64_t *)(window + (uintptr_t)(addr & ERX_BACKEND_VM_PAGE_MASK)), label,
	    memory_order_release);
	return (ERX_OK);
}

/* The lowest entry of the group record no object holds, or ERX_BACKEND_PARK_OBJECTS_MAX when all do. */
static uint32_t
irq_free_entry(uint32_t group)
{
	uint64_t used = 0;

	_Static_assert(ERX_BACKEND_PARK_OBJECTS_MAX == 64, "a group's entries fill one word");
	for (uint32_t slot = 0; slot < ERX_FIASCO_IRQS_MAX; slot++)
		if (irq_objects[slot].group == group + 1)
			used |= UINT64_C(1) << irq_objects[slot].entry;
	return (used == UINT64_MAX ? ERX_BACKEND_PARK_OBJECTS_MAX : (uint32_t)__builtin_ctzll(~used));
}

/*
 * Tries to make a waiting bind: once its group has a home with a dispatcher, stores
 * the label and binds the object to the dispatcher, setting made; a line stays masked
 * until the holder's ack.
 * Before then the bind keeps waiting, made stays false, and the result is ERX_OK; a
 * refusal of the label page or of the kernel's bind is ERX_EINVAL.
 */
static int
irq_try_make(irq_object_t *object)
{
	uint32_t home, dispatcher;

	if (!erx_fiasco_task_group_home(object->group - 1, &home) || erx_fiasco_task(home)->dispatcher == 0)
		return (ERX_OK);
	dispatcher = erx_fiasco_task(home)->dispatcher - 1;
	if (irq_label_store(home, object->entry, object->label) != ERX_OK)
		return (ERX_EINVAL);
	if (l4_error(l4_rcv_ep_bind_thread(irq_cap(object), (l4_cap_idx_t)erx_fiasco_task_thread_cap(home, dispatcher),
	    object->entry)) < 0)
		return (ERX_EINVAL);
	object->made = true;
	return (ERX_OK);
}

/*
 * The bind goes: Fiasco masks a line it detaches, and owes a software object's later
 * fire to the next bind. The entry's label is cleared first, so a delivery still
 * listed under it reports 0, which names no sink.
 */
static void
irq_unbind(irq_object_t *object)
{
	uint32_t home;

	if (object->made) {
		if (erx_fiasco_task_group_home(object->group - 1, &home))
			(void)irq_label_store(home, object->entry, 0);
		(void)l4_irq_detach(irq_cap(object));
	}
	object->group = IRQ_UNBOUND;
	object->made = false;
}

/*
 * Whether a line or an MSI object holds the interrupt: the object table is the one
 * record of it, and a wired line inside the frame's range is never taken for an MSI.
 */
static bool
irq_msi_held(uint32_t line, const void *context)
{
	(void)context;
	for (const irq_object_t *object = irq_objects; object < irq_objects + ERX_FIASCO_IRQS_MAX; object++)
		if (object->record != 0 && object->kind != ERX_IRQ_SOFT && object->line == line)
			return (true);
	return (false);
}

/* The interrupt id an object of the request's kind fires from: a line's selector, or the frame's lowest free line. */
static int
irq_line_choose(const erx_fiasco_irq_create_request_t *request, uint32_t *line)
{
	switch (request->kind) {
	case ERX_IRQ_LINE:
		*line = (uint32_t)request->selector;
		return (ERX_OK);
	case ERX_IRQ_MSI:
		return (erx_fiasco_msi_line_take(irq_msi_range, irq_msi_held, NULL, line));
	default:
		*line = 0;
		return (ERX_OK);
	}
}

/*
 * Attaches the slot's kernel object to its interrupt, false when the kernel will not:
 * a frame's line is set edge-triggered first, as every frame line is
 * (docs/design-platforms.md, "MSI frames").
 */
static bool
irq_attach(const irq_object_t *slot, uint32_t kind, uint32_t line)
{
	if (kind == ERX_IRQ_MSI && l4_error(l4_icu_set_mode(L4_BASE_ICU_CAP, line, L4_IRQ_F_POS_EDGE)) < 0)
		return (false);
	return (l4_error(l4_icu_bind(L4_BASE_ICU_CAP, line, irq_cap(slot))) >= 0);
}

/* The record's object, in the lowest free slot: a line's or an MSI's is attached to its interrupt here. */
static int
irq_fill(uint32_t record, const void *argument)
{
	const erx_fiasco_irq_create_request_t *const request = argument;
	const uint32_t kind = (uint32_t)request->kind;
	irq_object_t *object = irq_objects;
	uint32_t line;
	int status;

	while (object < irq_objects + ERX_FIASCO_IRQS_MAX && object->record != 0)
		object++;
	if (object == irq_objects + ERX_FIASCO_IRQS_MAX)
		return (ERX_ENOMEM);
	status = irq_line_choose(request, &line);
	if (status != ERX_OK)
		return (status);
	if (l4_error(l4_factory_create_irq(L4_BASE_FACTORY_CAP, irq_cap(object))) < 0)
		return (ERX_ENOMEM);
	if (kind != ERX_IRQ_SOFT && !irq_attach(object, kind, line)) {
		(void)l4_task_delete_obj(L4_BASE_TASK_CAP, irq_cap(object));
		return (ERX_EBUSY);
	}
	*object = (irq_object_t){ .record = record + 1, .kind = kind, .line = line };
	return (ERX_OK);
}

bool
erx_fiasco_irq_msi_frame(const erx_mf_msi_frame_t *frame)
{
	uint64_t doorbell;

	/* The reader bounds first and count each; a frame's lines and its doorbell are checked whole here. */
	if (frame->count != 0 && (frame->base == 0 || frame->first + frame->count > ERX_MSI_FRAME_LINES_MAX ||
	    __builtin_add_overflow(frame->base, IRQ_MSI_DOORBELL, &doorbell)))
		return (false);
	irq_msi_range = (erx_fiasco_msi_range_t){ .first = frame->first, .count = frame->count };
	irq_msi_doorbell = frame->count != 0 ? doorbell : 0;
	return (true);
}

int
erx_fiasco_irq_create_body(uint32_t task, const erx_fiasco_irq_create_request_t *request, erx_fiasco_reply_t *reply)
{
	irq_object_t *object;
	int status;

	if (request->kind != ERX_IRQ_SOFT && request->kind != ERX_IRQ_LINE && request->kind != ERX_IRQ_MSI)
		return (ERX_EINVAL);
	/* A line and an MSI are the root's alone. */
	if (task != ERX_FIASCO_TASK_ROOT && request->kind != ERX_IRQ_SOFT)
		return (ERX_ENOTSUP);
	/* A line names its interrupt; an MSI's is the frame's to choose, so it names none. */
	if (request->selector > UINT32_MAX || (request->kind == ERX_IRQ_MSI && request->selector != 0))
		return (ERX_EINVAL);
	status = erx_fiasco_object_create(task, ERX_BACKEND_OBJECT_IRQ, request->budget, irq_fill, request, &reply->first);
	if (status != ERX_OK || request->kind != ERX_IRQ_MSI)
		return (status);
	/* The message comes from the line the fill took; the handle was just given, so it names the object. */
	status = irq_named(task, reply->first, &object);
	if (status == ERX_OK) {
		reply->second = irq_msi_doorbell;
		reply->third = object->line;
	}
	return (status);
}

/*
 * Whether the task may bind into the group record, or move or unbind an object bound
 * there: the root in any group it holds; any other task in the group it is the home of
 * (docs/design-fiasco.md, "Device records"), so a holder's driver binds the line it was
 * given to its own group and reaches no other domain's; and in a group it created, so a
 * session binds a program's doorbell into the program's group, whose home is the
 * program (docs/design-programs.md, "The channel"). A group's home is its creator or a
 * space below it, since group handles pass only down and a thread is created only in
 * its caller's own space or one the caller created. A task's row names the one group
 * it is the home of (group.c), the group's record its creator, and both are live.
 */
static bool
irq_group_allowed(uint32_t task, uint32_t group)
{
	return (task == ERX_FIASCO_TASK_ROOT || erx_fiasco_task(task)->group == group + 1 ||
	    erx_fiasco_object_at(group)->creator == task);
}

/* ERX_CAP_SELF names the caller's home group, which the root's first group is for the root. */
static int
irq_group_named(uint32_t task, uint64_t group, uint32_t *record)
{
	if (group != ERX_CAP_SELF)
		return (erx_fiasco_object_find(task, group, ERX_BACKEND_OBJECT_GROUP, record));
	if (erx_fiasco_task(task)->group == 0)
		return (ERX_EINVAL);
	*record = erx_fiasco_task(task)->group - 1;
	return (ERX_OK);
}

int
erx_fiasco_irq_bind_body(uint32_t task, const erx_fiasco_irq_bind_request_t *request)
{
	irq_object_t *object;
	uint32_t group, entry, home;
	int status;

	status = irq_named(task, request->irq, &object);
	if (status == ERX_OK)
		status = irq_group_named(task, request->group, &group);
	if (status != ERX_OK)
		return (status);
	/* The target, and the group a bound object is in, must both be the caller's to name. */
	if (!irq_group_allowed(task, group) || (object->group != IRQ_UNBOUND && !irq_group_allowed(task, object->group - 1)))
		return (ERX_ETYPE);
	if (object->group != IRQ_UNBOUND) {
		/* A move changes only the label a later take reads: the dispatcher stays its receiver. */
		if (object->group != group + 1)
			return (ERX_ENOTSUP);
		if (object->made && erx_fiasco_task_group_home(group, &home)) {
			status = irq_label_store(home, object->entry, request->label);
			if (status != ERX_OK)
				return (status);
		}
		object->label = request->label;
		return (ERX_OK);
	}
	entry = irq_free_entry(group);
	if (entry == ERX_BACKEND_PARK_OBJECTS_MAX)
		return (ERX_ELIMIT);
	/* A new bind starts unacknowledged: an unbind left the line masked, as a create did. */
	object->group = group + 1;
	object->entry = entry;
	object->label = request->label;
	status = irq_try_make(object);
	if (status != ERX_OK)
		irq_unbind(object);
	return (status);
}

int
erx_fiasco_irq_unbind_body(uint32_t task, uint64_t irq)
{
	irq_object_t *object;
	int status = irq_named(task, irq, &object);

	if (status == ERX_OK && object->group != IRQ_UNBOUND && !irq_group_allowed(task, object->group - 1))
		status = ERX_ETYPE;
	if (status == ERX_OK)
		irq_unbind(object);
	return (status);
}

int
erx_fiasco_irq_place(uint32_t task, uint32_t record, uint64_t handle, uint32_t rights)
{
	const uint32_t index = ERX_BACKEND_HANDLE_NUMBER(handle) - 1;

	if ((rights & (ERX_HR_TRIGGER | ERX_HR_ACK)) == 0)
		return (ERX_OK);
	return (l4_error(l4_task_map(erx_fiasco_task_cap(task), L4_BASE_TASK_CAP,
	    l4_obj_fpage(irq_cap(irq_of(record)), 0, L4_CAP_FPAGE_RO),
	    l4_map_obj_control(erx_fiasco_irq_slot_cap(index), L4_MAP_ITEM_MAP))) < 0 ? ERX_ENOMEM : ERX_OK);
}

void
erx_fiasco_irq_unplace(uint32_t task, uint64_t handle)
{
	const uint32_t index = ERX_BACKEND_HANDLE_NUMBER(handle) - 1;

	(void)l4_task_unmap(erx_fiasco_task_cap(task), l4_obj_fpage(erx_fiasco_irq_slot_cap(index), 0, L4_CAP_FPAGE_RWSD),
	    L4_FP_ALL_SPACES);
}

void
erx_fiasco_irq_free(uint32_t record)
{
	irq_object_t *const object = irq_of(record);

	if (object == NULL)
		return;
	irq_unbind(object);
	(void)l4_task_delete_obj(L4_BASE_TASK_CAP, irq_cap(object));
	*object = (irq_object_t){ 0 };
}

/* A bind the kernel refuses here has no caller to tell, so it goes, leaving the object unbound. */
void
erx_fiasco_irq_group_ready(uint32_t record)
{
	for (irq_object_t *object = irq_objects; object < irq_objects + ERX_FIASCO_IRQS_MAX; object++) {
		if (object->group != record + 1 || object->made)
			continue;
		if (irq_try_make(object) != ERX_OK)
			irq_unbind(object);
	}
}

void
erx_fiasco_irq_group_end(uint32_t record)
{
	for (uint32_t slot = 0; slot < ERX_FIASCO_IRQS_MAX; slot++)
		if (irq_objects[slot].group == record + 1)
			irq_unbind(&irq_objects[slot]);
}

#ifdef ERX_FIASCO_TEST_HOOKS
static bool
irq_slot_empty(l4_cap_idx_t slot)
{
	return (l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, slot)) == 0);
}

static void
irq_probe_place(l4_cap_idx_t from, l4_cap_idx_t to)
{
	(void)l4_task_map(L4_BASE_TASK_CAP, L4_BASE_TASK_CAP, l4_obj_fpage(from, 0, L4_CAP_FPAGE_RO),
	    l4_map_obj_control(to, L4_MAP_ITEM_MAP));
}

/*
 * The boot probe of docs/design-fiasco.md, "Handles": in the root's own space, a capability
 * placed at slot 65,535, the last slot of the last window erx_space_create admits, holds,
 * one at 65,536 is refused, and the slot before them stays empty; a selector 2^39 above
 * that empty slot does not reach it either. The root's slot 65,535 is its last task run's,
 * which a test machine never makes. The capability is the one placed for the root's
 * handle irq; the result is NULL, or the failure line.
 */
const char *
erx_fiasco_test_object_space_probe(uint64_t irq)
{
	const l4_cap_idx_t placed = (l4_cap_idx_t)erx_fiasco_irq_slot_cap(ERX_BACKEND_HANDLE_NUMBER(irq) - 1);
	const l4_cap_idx_t last = (l4_cap_idx_t)(ERX_FIASCO_OBJ_SPACE_SLOTS - 1) << L4_CAP_SHIFT;
	const l4_cap_idx_t before = last - L4_CAP_OFFSET, past = last + L4_CAP_OFFSET;
	const l4_cap_idx_t alias = before + ((l4_cap_idx_t)1 << (39 + L4_CAP_SHIFT));
	const char *reason = NULL;

	_Static_assert(ERX_FIASCO_IRQ_SLOT_BASE + ERX_FIASCO_CAP_LIMIT_MAX - 2 == ERX_FIASCO_OBJ_SPACE_SLOTS - 1,
	    "the last window's last slot is the object space's");
	_Static_assert(ERX_FIASCO_SLOT_FIRST + ERX_FIASCO_THREADS_MAX + ERX_FIASCO_SLOT_END == ERX_FIASCO_OBJ_SPACE_SLOTS,
	    "the root's last task run ends at the object space's last slot");
	if (irq_slot_empty(placed) || !irq_slot_empty(before) || !irq_slot_empty(last))
		return ("erx: irq: the probe's slots are not as the layout says FAILED\n");
	irq_probe_place(placed, last);
	if (irq_slot_empty(last) || l4_msgtag_label(l4_task_cap_equal(L4_BASE_TASK_CAP, placed, last)) != 1)
		reason = "erx: irq: no capability at the object space's last slot FAILED\n";
	irq_probe_place(placed, past);
	if (reason == NULL && !irq_slot_empty(past))
		reason = "erx: irq: a capability past the object space's last slot FAILED\n";
	irq_probe_place(placed, alias);
	if (reason == NULL && (!irq_slot_empty(before) || irq_slot_empty(last)))
		reason = "erx: irq: a selector 2^39 above a slot reached it FAILED\n";
	(void)l4_task_unmap(L4_BASE_TASK_CAP, l4_obj_fpage(last, 0, L4_CAP_FPAGE_RWSD), L4_FP_ALL_SPACES);
	if (reason == NULL && !irq_slot_empty(last))
		reason = "erx: irq: the probe's capability stayed FAILED\n";
	return (reason);
}
#endif
