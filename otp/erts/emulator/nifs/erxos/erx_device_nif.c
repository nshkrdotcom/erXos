/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's NIF calls (docs/design-runtime.md, "The device NIF"): opening a
 * device, which interns its table's names as atoms for the BIFs, binding a line to the
 * calling process and naming the process a line is bound to, a device's queues: creating one, the device's initialisation, posting a
 * chain and completing what the device returned, and a device's regions, whose memory erx_region_view shows erx_memdraw. A binding is a resource monitoring that process, kept by the line's
 * entry, which every record naming the line shares: its exit unbinds the line unless a later binding has moved it, so the late exit of a crashed driver never
 * undoes its successor's binding.
 *
 * One lock serialises opens, everything a binding changes and every queue call. It is taken before the event
 * table's lock and held across service calls; a dispatch, which holds the event table's
 * lock, never takes it.
 */

#define STATIC_ERLANG_NIF 1

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "erl_nif.h"
#include "sys.h"
#include "erx_event.h"

#include "erx_device.h"
#include "erx_device_genet.h"
#include "erx_device_xhci.h"
#include "erx_framebuffer.h"
#include "erx_region.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"

#define ATOM_TEXT_MAX	64u

/*
 * A line's binding. The reference enif_alloc_resource gives lasts as long as the monitor:
 * whoever ends the monitor releases it, binding_down when it fired and retire_former when a
 * demonitor got there first. ERTS's monitor holds no reference of its own.
 */
typedef struct binding {
	uint32_t	device;		/* the record and its line the binding was made through */
	uint32_t	line;
	uint32_t	entry;
	uint32_t	label;
	ErlNifPid	pid;
	ErlNifMonitor	monitor;
} binding_t;

static ErlNifMutex *device_lock;
static ErlNifResourceType *binding_type;
static binding_t *bindings[ERX_DEVICE_LINE_ENTRIES_MAX];

static ERL_NIF_TERM
status_error(ErlNifEnv *env, int status)
{
	const char *name;

	switch (status) {
	case ERX_EINVAL:	name = "einval"; break;
	case ERX_ESTALE:	name = "estale"; break;
	case ERX_ENOTSUP:	name = "enotsup"; break;
	case ERX_ENOMEM:	name = "enomem"; break;
	case ERX_EBUSY:		name = "ebusy"; break;
	case ERX_ERANGE:	name = "erange"; break;
	case ERX_ERIGHTS:	name = "erights"; break;
	case ERX_ELIMIT:	name = "elimit"; break;
	case ERX_EWOULDBLOCK:	name = "full"; break;
	case ERX_ECORRUPT:	name = "broken"; break;
	default:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"),
		    enif_make_tuple2(env, enif_make_atom(env, "status"), enif_make_int(env, status))));
	}
	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, name)));
}

/* A tuple of `arity` whose first element is the atom `tag`, and its elements. */
static bool
tagged(ErlNifEnv *env, ERL_NIF_TERM term, const char *tag, int arity, const ERL_NIF_TERM **parts)
{
	int found;

	return (enif_get_tuple(env, term, &found, parts) && found == arity &&
	    enif_is_identical((*parts)[0], enif_make_atom(env, tag)));
}

/*
 * `{object, Window, Offset, Size}` for a given device, `{physical, Base, Size}`, or `stand_in`
 * for a hosted test's plain memory.
 */
static bool
decode_window(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_spec_t *spec)
{
	const ERL_NIF_TERM *parts;
	ErlNifUInt64 window, base, size;

	if (enif_is_identical(term, enif_make_atom(env, "stand_in"))) {
		spec->form = ERX_DEVICE_FORM_STAND_IN;
		return (true);
	}
	if (tagged(env, term, "object", 4, &parts) && enif_get_uint64(env, parts[1], &window) &&
	    enif_get_uint64(env, parts[2], &base) && enif_get_uint64(env, parts[3], &size)) {
		spec->form = ERX_DEVICE_FORM_GIVEN;
		spec->window = window;
	} else if (!tagged(env, term, "physical", 3, &parts) || !enif_get_uint64(env, parts[1], &base) ||
	    !enif_get_uint64(env, parts[2], &size)) {
		return (false);
	}
	spec->base = base;
	spec->size = size;
	return (true);
}

/*
 * A given device's line is `{object, Irq}`; any other's is its selector. A line two devices
 * of the unit name is marked `{shared, Line}` by the record's writer.
 */
static bool
decode_line(ErlNifEnv *env, ERL_NIF_TERM term, const erx_device_spec_t *spec, uint64_t *line, bool *shared)
{
	const ERL_NIF_TERM *parts;
	ErlNifUInt64 value;

	*shared = tagged(env, term, "shared", 2, &parts);
	if (*shared)
		term = parts[1];
	if (spec->form == ERX_DEVICE_FORM_GIVEN) {
		if (!tagged(env, term, "object", 2, &parts))
			return (false);
		term = parts[1];
	}
	if (!enif_get_uint64(env, term, &value))
		return (false);
	*line = value;
	return (true);
}

/* A given device's `memory => {object, Memory, Bytes}`, Bytes nonzero, which no other form has. */
static bool
decode_memory(ErlNifEnv *env, ERL_NIF_TERM map, erx_device_spec_t *spec)
{
	const ERL_NIF_TERM *parts;
	ERL_NIF_TERM value;
	ErlNifUInt64 memory, bytes;

	if (!enif_get_map_value(env, map, enif_make_atom(env, "memory"), &value))
		return (true);
	if (spec->form != ERX_DEVICE_FORM_GIVEN || !tagged(env, value, "object", 3, &parts) ||
	    !enif_get_uint64(env, parts[1], &memory) || !enif_get_uint64(env, parts[2], &bytes) || bytes == 0)
		return (false);
	spec->memory = memory;
	spec->memory_size = bytes;
	return (true);
}

/* One unsigned field `name` of a map, at most `max`. */
static bool
map_uint(ErlNifEnv *env, ERL_NIF_TERM map, const char *name, uint64_t max, uint64_t *out)
{
	ERL_NIF_TERM value;
	ErlNifUInt64 number;

	if (!enif_get_map_value(env, map, enif_make_atom(env, name), &value) || !enif_get_uint64(env, value, &number) ||
	    number > max)
		return (false);
	*out = number;
	return (true);
}

/*
 * A given PCIe function's `msix => #{address, data, bar, offset, entries}`, its MSI-X route as
 * erx_device_record reads it, which no other form has. The reader refuses a table outside the
 * window's BAR, so the window is the table's BAR and `bar` is not read here. A table of no
 * entries is refused: erx_device.c takes 0 entries for no MSI-X route at all.
 */
static bool
decode_msix(ErlNifEnv *env, ERL_NIF_TERM map, erx_device_spec_t *spec)
{
	ERL_NIF_TERM value;
	uint64_t data, entries;

	if (!enif_get_map_value(env, map, enif_make_atom(env, "msix"), &value))
		return (true);
	if (spec->form != ERX_DEVICE_FORM_GIVEN || !enif_is_map(env, value) ||
	    !map_uint(env, value, "address", UINT64_MAX, &spec->msix.address) ||
	    !map_uint(env, value, "data", UINT32_MAX, &data) ||
	    !map_uint(env, value, "offset", UINT32_MAX, &spec->msix.offset) ||
	    !map_uint(env, value, "entries", UINT32_MAX, &entries) || entries == 0)
		return (false);
	spec->msix.data = (uint32_t)data;
	spec->msix.entries = (uint32_t)entries;
	return (true);
}

/*
 * #{peripheral := atom(), window := window(), lines := [line() | {shared, line()}], memory => memory(),
 * coherent => boolean(), msix => msix()}. A device the spec does not mark coherent is taken as not
 * coherent.
 */
static bool
decode_spec(ErlNifEnv *env, ERL_NIF_TERM term, char *peripheral, erx_device_spec_t *spec)
{
	ERL_NIF_TERM value, list, head;
	unsigned length;

	if (!enif_get_map_value(env, term, enif_make_atom(env, "peripheral"), &value))
		return (false);
	const int written = enif_get_atom(env, value, peripheral, ATOM_TEXT_MAX, ERL_NIF_LATIN1);

	if (written <= 0)
		return (false);
	spec->peripheral = peripheral;
	spec->peripheral_length = (size_t)written - 1;
	if (!enif_get_map_value(env, term, enif_make_atom(env, "window"), &value) || !decode_window(env, value, spec))
		return (false);
	if (!enif_get_map_value(env, term, enif_make_atom(env, "lines"), &list) ||
	    !enif_get_list_length(env, list, &length) || length > ERX_DEVICE_LINES_MAX)
		return (false);
	spec->line_count = length;
	for (unsigned index = 0; index < length; index++) {
		if (!enif_get_list_cell(env, list, &head, &list) || !decode_line(env, head, spec, &spec->lines[index], &spec->shared[index]))
			return (false);
	}
	if (enif_get_map_value(env, term, enif_make_atom(env, "coherent"), &value)) {
		spec->coherent = enif_is_identical(value, enif_make_atom(env, "true"));
		if (!spec->coherent && !enif_is_identical(value, enif_make_atom(env, "false")))
			return (false);
	}
	return (decode_memory(env, term, spec) && decode_msix(env, term, spec));
}

static ERL_NIF_TERM
open_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uintptr_t register_keys[ERX_DEVICE_REGISTERS_MAX], field_keys[ERX_DEVICE_FIELDS_MAX];
	char peripheral_name[ATOM_TEXT_MAX];
	erx_device_spec_t spec = { 0 };
	const erx_device_peripheral_t *peripheral;
	uint32_t device;
	int status;

	(void)argc;
	if (!decode_spec(env, argv[0], peripheral_name, &spec))
		return (enif_make_badarg(env));
	peripheral = erx_device_peripheral_find(spec.peripheral, spec.peripheral_length);
	if (peripheral == NULL)
		return (enif_make_badarg(env));
	/* The table's names, which only the checked-in SVD files choose. */
	for (uint32_t index = 0; index < peripheral->register_count; index++)
		register_keys[index] = (uintptr_t)enif_make_atom(env, peripheral->registers[index].name);
	for (uint32_t index = 0; index < peripheral->field_count; index++)
		field_keys[index] = (uintptr_t)enif_make_atom(env, peripheral->fields[index].name);
	enif_mutex_lock(device_lock);
	status = erx_device_open(&spec, register_keys, field_keys, &device);
	enif_mutex_unlock(device_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, device)));
}

/* All or nothing: the label is registered, the process monitored and the object reporting the label. */
static int
start_binding(ErlNifEnv *env, binding_t *binding, ERL_NIF_TERM message, uint64_t irq)
{
	ErlNifPid self;
	int status;

	enif_self(env, &self);
	binding->pid = self;
	status = erx_event_register_process(&self, message, &binding->label);
	if (status != ERX_OK)
		return (status);
	/* Only a process past its exit is unmonitorable, and this one is running this call. */
	if (enif_monitor_process(env, binding, &self, &binding->monitor) != 0) {
		erx_event_unregister(binding->label);
		return (ERX_EINVAL);
	}
	status = erx_irq_bind(irq, ERX_CAP_SELF, binding->label);
	if (status != ERX_OK) {
		(void)enif_demonitor_process(env, binding, &binding->monitor);
		erx_event_unregister(binding->label);
	}
	return (status);
}

/* The object reports a later label, so the former binding has nothing left to deliver. */
static void
retire_former(ErlNifEnv *env, binding_t *former)
{
	erx_event_unregister(former->label);
	if (enif_demonitor_process(env, former, &former->monitor) == 0)
		enif_release_resource(former);
}

/* What a refused bind answers: badarg for a line the record lacks, a refusal for the rest. */
static ERL_NIF_TERM
bind_refusal(ErlNifEnv *env, erx_device_bind_t decision)
{
	switch (decision) {
	case ERX_DEVICE_BIND_SHARED:	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "shared")));
	case ERX_DEVICE_BIND_DIRECT:	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "direct")));
	case ERX_DEVICE_BIND_BUSY:	return (status_error(env, ERX_EBUSY));
	case ERX_DEVICE_BIND_OK:
	case ERX_DEVICE_BIND_NO_LINE:
	default:			return (enif_make_badarg(env));
	}
}

/*
 * irq_bind/2 and irq_bind_owner/2: the line's mark decides which of them binds it
 * (erx_device_bind_check), and a bind through the record the line is bound through moves
 * the binding to the caller.
 */
static ERL_NIF_TERM
bind_line(ErlNifEnv *env, const ERL_NIF_TERM argv[], erx_device_binder_t binder)
{
	unsigned device_index, line_index;
	const erx_device_t *device;
	erx_device_bind_t decision;
	binding_t *binding, *former;
	uint32_t entry;
	uint64_t irq;
	int status;

	if (!enif_get_uint(env, argv[0], &device_index) || !enif_get_uint(env, argv[1], &line_index))
		return (enif_make_badarg(env));
	device = erx_device_get(device_index);
	if (device == NULL || !erx_device_line_irq(device, line_index, &irq) || !erx_device_line_entry(device, line_index, &entry))
		return (enif_make_badarg(env));
	binding = enif_alloc_resource(binding_type, sizeof(*binding));
	if (binding == NULL)
		return (status_error(env, ERX_ENOMEM));
	binding->device = device_index;
	binding->line = line_index;
	binding->entry = entry;

	const ERL_NIF_TERM message = enif_make_tuple3(env, enif_make_atom(env, "erx_irq"), argv[0], argv[1]);

	enif_mutex_lock(device_lock);
	former = bindings[entry];
	decision = erx_device_bind_check(device, line_index, binder, former != NULL ? erx_device_get(former->device) : NULL,
	    former != NULL ? former->line : 0);
	if (decision != ERX_DEVICE_BIND_OK) {
		enif_mutex_unlock(device_lock);
		enif_release_resource(binding);
		return (bind_refusal(env, decision));
	}
	status = start_binding(env, binding, message, irq);
	if (status != ERX_OK) {
		enif_mutex_unlock(device_lock);
		enif_release_resource(binding);
		return (status_error(env, status));
	}
	if (former != NULL)
		retire_former(env, former);
	bindings[entry] = binding;
	/* A line a former binder left masked opens for this one; a level still asserted fires at once. */
	status = erx_irq_ack(irq);
	enif_mutex_unlock(device_lock);
	return (status == ERX_OK ? enif_make_atom(env, "ok") : status_error(env, status));
}

static ERL_NIF_TERM
irq_bind_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	return (bind_line(env, argv, ERX_DEVICE_BINDER_DRIVER));
}

static ERL_NIF_TERM
irq_bind_owner_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	return (bind_line(env, argv, ERX_DEVICE_BINDER_OWNER));
}

/* irq_holder(Dev, Line): the process the line is bound to, through any record naming it. */
static ERL_NIF_TERM
irq_holder_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned device_index, line_index;
	const erx_device_t *device;
	ERL_NIF_TERM result;
	uint32_t entry;

	(void)argc;
	if (!enif_get_uint(env, argv[0], &device_index) || !enif_get_uint(env, argv[1], &line_index))
		return (enif_make_badarg(env));
	device = erx_device_get(device_index);
	if (device == NULL || !erx_device_line_entry(device, line_index, &entry))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	if (bindings[entry] != NULL)
		result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_pid(env, &bindings[entry]->pid));
	else
		result = enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "unbound"));
	enif_mutex_unlock(device_lock);
	return (result);
}

/*
 * The monitored process exited. A binding that a later one has moved no longer names its
 * line, and the move has done the rest. A refused unbind has no one to tell: the label it
 * would have stopped names nothing, so a delivery under it is dropped.
 */
static void
binding_down(ErlNifEnv *env, void *object, ErlNifPid *pid, ErlNifMonitor *monitor)
{
	binding_t *const binding = object;
	uint64_t irq;

	(void)env;
	(void)pid;
	(void)monitor;
	enif_mutex_lock(device_lock);
	if (bindings[binding->entry] == binding) {
		if (erx_device_line_irq(erx_device_get(binding->device), binding->line, &irq))
			(void)erx_irq_bind(irq, ERX_CAP_NULL, 0);
		erx_event_unregister(binding->label);
		bindings[binding->entry] = NULL;
	}
	enif_mutex_unlock(device_lock);
	enif_release_resource(binding);
}

/* The open device a term names, or NULL. */
static const erx_device_t *
device_of(ErlNifEnv *env, ERL_NIF_TERM term)
{
	unsigned index;

	return (enif_get_uint(env, term, &index) ? erx_device_get(index) : NULL);
}

/* The device's configuration space named by the atom, or NULL. */
static const erx_device_space_t *
space_of(ErlNifEnv *env, const erx_device_t *device, ERL_NIF_TERM name)
{
	char text[ATOM_TEXT_MAX];
	const int written = enif_get_atom(env, name, text, sizeof(text), ERL_NIF_LATIN1);

	return (written > 0 ? erx_device_space_named(erx_device_peripheral(device), text, (size_t)written - 1) : NULL);
}

/*
 * elements(Dev, Name): how many elements of the register the device's open resolved, or how
 * many blocks of the configuration space lie inside its window.
 */
static ERL_NIF_TERM
elements_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	const erx_device_register_t *reg;
	const erx_device_space_t *space;

	(void)argc;
	if (device == NULL || !enif_is_atom(env, argv[1]))
		return (enif_make_badarg(env));
	/* The record's keys are the atoms open/1 made of the table's names. */
	if ((reg = erx_device_register_by_key(device, (uintptr_t)argv[1])) != NULL)
		return (enif_make_uint(env, erx_device_elements(device, reg)));
	if ((space = space_of(env, device, argv[1])) != NULL)
		return (enif_make_uint(env, erx_device_space_elements(device, space)));
	return (enif_make_badarg(env));
}

/* A configuration access's terms: Dev, Space (an atom, or {Atom, Index} for a block of an array), Offset and Width. */
typedef struct config_access {
	const erx_device_t		*device;
	const erx_device_space_t	*space;
	erx_device_element_t		 element;
	uint64_t			 offset;
	uint64_t			 width;
} config_access_t;

static bool
decode_config(ErlNifEnv *env, const ERL_NIF_TERM argv[], config_access_t *access)
{
	ERL_NIF_TERM name = argv[1];
	const ERL_NIF_TERM *pair;
	int arity;

	access->device = device_of(env, argv[0]);
	access->element = (erx_device_element_t){ .indexed = false, .index = 0 };
	if (access->device == NULL || !enif_get_uint64(env, argv[2], &access->offset) ||
	    !enif_get_uint64(env, argv[3], &access->width))
		return (false);
	if (enif_get_tuple(env, argv[1], &arity, &pair)) {
		if (arity != 2 || !enif_get_uint64(env, pair[1], &access->element.index))
			return (false);
		name = pair[0];
		access->element.indexed = true;
	}
	access->space = space_of(env, access->device, name);
	return (access->space != NULL);
}

/* config_read(Dev, Space, Offset, Width): Width bytes at Offset of the space's block. */
static ERL_NIF_TERM
config_read_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	config_access_t access;
	uint64_t value;

	(void)argc;
	if (!decode_config(env, argv, &access) ||
	    !erx_device_config_read(access.device, access.space, access.element, access.offset, access.width, &value))
		return (enif_make_badarg(env));
	return (enif_make_uint64(env, value));
}

/* config_write(Dev, Space, Offset, Width, Value) */
static ERL_NIF_TERM
config_write_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	config_access_t access;
	uint64_t value;

	(void)argc;
	if (!decode_config(env, argv, &access) || !enif_get_uint64(env, argv[4], &value) ||
	    !erx_device_config_write(access.device, access.space, access.element, access.offset, access.width, value))
		return (enif_make_badarg(env));
	return (enif_make_atom(env, "ok"));
}

/* queue_create(Dev, Queue, Size, BufferSize) */
static ERL_NIF_TERM
queue_create_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	unsigned index, size, buffer_size;
	uint32_t queue;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &index) || !enif_get_uint(env, argv[2], &size) ||
	    !enif_get_uint(env, argv[3], &buffer_size))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_queue_create(device, index, size, buffer_size, &queue);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, queue)));
}

/*
 * negotiate(Dev, Wanted | continue): `continue` carries on the TRB form's negotiation, a number begins
 * one; `reset` from the TRB form's call that ends the controller's reset.
 */
static ERL_NIF_TERM
negotiate_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	const bool continues = enif_is_identical(argv[1], enif_make_atom(env, "continue"));
	ErlNifUInt64 wanted = 0;
	uint64_t accepted;
	int status;

	(void)argc;
	if (device == NULL || (!continues && !enif_get_uint64(env, argv[1], &wanted)))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_negotiate(device, wanted, continues, &accepted);
	enif_mutex_unlock(device_lock);
	if (status == ERX_DEVICE_RESET_DONE)
		return (enif_make_atom(env, "reset"));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint64(env, accepted)));
}

/* region(Dev, Index, Bytes) */
static ERL_NIF_TERM
region_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	ErlNifUInt64 bytes;
	unsigned index;
	uint32_t region;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &index) || !enif_get_uint64(env, argv[2], &bytes))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_region(device, index, bytes, &region);
	enif_mutex_unlock(device_lock);
	/* No bytes, or the same region with other bytes. */
	if (status == ERX_EINVAL || status == ERX_EBUSY)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, region)));
}

/*
 * framebuffer(): the domain's own framebuffer, the window of its framebuffer record that the
 * boot page carries (erx_runtime_framebuffer), so no handle from Erlang is mapped; {error,
 * enoent} for a domain the page gives no single well-formed record.
 */
static ERL_NIF_TERM
framebuffer_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_boot_framebuffer_t record;
	uint32_t framebuffer;
	int status;

	(void)argc;
	(void)argv;
	if (!erx_runtime_framebuffer(&record))
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "enoent")));
	enif_mutex_lock(device_lock);
	status = erx_device_framebuffer(record.window, record.offset, record.size, &framebuffer);
	enif_mutex_unlock(device_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, framebuffer)));
}

/* A framebuffer's mapping for erx_memdraw (erx_framebuffer.h): the term is its name. */
bool
erx_framebuffer_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_framebuffer_view_t *out)
{
	unsigned framebuffer;
	uint64_t bytes;

	if (!enif_get_uint(env, term, &framebuffer) || !erx_device_framebuffer_memory(framebuffer, &out->base, &bytes))
		return (false);
	out->bytes = (size_t)bytes;
	return (true);
}

/* A region's mapping for erx_memdraw (erx_region.h): the term is the region's name. */
bool
erx_region_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_region_view_t *out)
{
	unsigned region;
	uint64_t bytes;

	if (!enif_get_uint(env, term, &region) || !erx_device_region_memory(region, &out->base, &bytes))
		return (false);
	out->bytes = (size_t)bytes;
	return (true);
}

/*
 * One `{out, Binary}`, `{out, {region, R}}` or `{in, Length}`. An out piece is a binary, never
 * an iolist, so its size is known before anything is copied, and its bytes stay valid for the
 * call as a term of it. A region piece carries only the region's name: erx_device_post writes
 * its entry, and refuses a region the device does not have.
 */
static bool
decode_piece(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_piece_t *piece)
{
	const ERL_NIF_TERM *pair, *region;
	ErlNifBinary bytes;
	unsigned length, name;
	int arity;

	if (!enif_get_tuple(env, term, &arity, &pair) || arity != 2)
		return (false);
	if (enif_is_identical(pair[0], enif_make_atom(env, "out")) && tagged(env, pair[1], "region", 2, &region)) {
		if (!enif_get_uint(env, region[1], &name))
			return (false);
		*piece = (erx_device_piece_t){ .names_region = true, .region = name };
		return (true);
	}
	if (enif_is_identical(pair[0], enif_make_atom(env, "out"))) {
		if (!enif_inspect_binary(env, pair[1], &bytes) || bytes.size > ERX_DEVICE_BUFFER_MAX)
			return (false);
		*piece = (erx_device_piece_t){ .device_writes = false, .data = bytes.data, .length = (uint32_t)bytes.size };
		return (true);
	}
	if (!enif_is_identical(pair[0], enif_make_atom(env, "in")) || !enif_get_uint(env, pair[1], &length))
		return (false);
	*piece = (erx_device_piece_t){ .device_writes = true, .data = NULL, .length = length };
	return (true);
}

/* post(Dev, Q, Tag, Segments) on a split ring or GENET queue */
static ERL_NIF_TERM
queue_post(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	erx_device_piece_t pieces[ERX_DEVICE_CHAIN_MAX];
	ERL_NIF_TERM list = argv[3], head;
	ErlNifUInt64 tag;
	unsigned queue, count = 0;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &queue) || !enif_get_uint64(env, argv[2], &tag))
		return (enif_make_badarg(env));
	while (enif_get_list_cell(env, list, &head, &list)) {
		if (count == ERX_DEVICE_CHAIN_MAX || !decode_piece(env, head, &pieces[count]))
			return (enif_make_badarg(env));
		count++;
	}
	if (!enif_is_empty_list(env, list))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_post(device, queue, tag, pieces, count);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	return (status == ERX_OK ? enif_make_atom(env, "ok") : status_error(env, status));
}

/*
 * What complete_nif collects, one `{Tag, Binary}` per completion, and stand_in_transmitted_nif,
 * one binary per frame: at most the queue's size.
 */
typedef struct completions {
	ErlNifEnv	*env;
	uint32_t	count;
	ERL_NIF_TERM	terms[ERX_DEVICE_QUEUE_SIZE_MAX];
} completions_t;

/* A fresh binary for each completion, so no term ever aliases memory the device can write. */
static uint8_t *
completion_sink(void *context, uint64_t tag, uint32_t length)
{
	completions_t *const completions = context;
	ERL_NIF_TERM binary;
	uint8_t *const bytes = enif_make_new_binary(completions->env, length, &binary);

	completions->terms[completions->count++] = enif_make_tuple2(completions->env,
	    enif_make_uint64(completions->env, tag), binary);
	return (bytes);
}

/* complete(Dev, Q) on a split ring or GENET queue */
static ERL_NIF_TERM
queue_complete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	completions_t completions = { .env = env };
	unsigned queue;
	uint32_t count;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &queue))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_complete(device, queue, completion_sink, &completions, &count);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_list_from_array(env, completions.terms, count)));
}

/*
 * The TRB ring form's calls on an xHCI controller (docs/design-usb.md, "The TRB ring form"). Each
 * term is decoded here into the form's types, every integer checked once to fit the field it
 * fills; ranges and queue states are the form's to judge (erx_device_trb.h's checks), whose
 * REFUSE_BADARG is badarg too. A map is read by the keys the design names: a missing one is
 * badarg, any other is ignored. No atom is made from a term.
 */

_Static_assert(sizeof(unsigned) == sizeof(uint32_t), "enif_get_uint fills a uint32_t");

/* Whether `term` is the atom `name`. */
static bool
is(ErlNifEnv *env, ERL_NIF_TERM term, const char *name)
{
	return (enif_is_identical(term, enif_make_atom(env, name)));
}

static bool
map_term(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, ERL_NIF_TERM *value)
{
	return (enif_get_map_value(env, map, enif_make_atom(env, key), value));
}

static bool
map_u64(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, uint64_t *out)
{
	ERL_NIF_TERM value;
	ErlNifUInt64 number;

	if (!map_term(env, map, key, &value) || !enif_get_uint64(env, value, &number))
		return (false);
	*out = number;
	return (true);
}

/* A boolean as the context's one-bit field. */
static bool
map_flag(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, uint64_t *out)
{
	ERL_NIF_TERM value;

	if (!map_term(env, map, key, &value))
		return (false);
	*out = is(env, value, "true") ? 1u : 0u;
	return (*out == 1u || is(env, value, "false"));
}

/* Address Device's `tt`: `none`, or #{hub_slot, port, multi} of the hub whose translator serves the device. */
static bool
decode_tt(ErlNifEnv *env, ERL_NIF_TERM term, erx_xhci_slot_context_free_t *slot)
{
	return (is(env, term, "none") || (enif_is_map(env, term) && map_u64(env, term, "hub_slot", &slot->tt_tt_slot) &&
	    map_u64(env, term, "port", &slot->tt_tt_port) && map_flag(env, term, "multi", &slot->route_multi_tt)));
}

/* #{route, root_port, speed, tt, ep0_packet}: the slot context's device fields and EP0, the one add. */
static bool
decode_address(ErlNifEnv *env, ERL_NIF_TERM map, erx_trb_command_t *command)
{
	erx_xhci_slot_context_free_t *const slot = &command->slot_context;
	erx_xhci_endpoint_context_free_t *const ep0 = &command->adds[0].context;
	ERL_NIF_TERM tt;

	command->add_count = 1;
	command->adds[0].dci = 1;
	ep0->config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL;
	return (enif_is_map(env, map) && map_u64(env, map, "route", &slot->route_route_string) &&
	    map_u64(env, map, "root_port", &slot->ports_root_port) && map_u64(env, map, "speed", &slot->route_speed) &&
	    map_u64(env, map, "ep0_packet", &ep0->config_max_packet) && map_term(env, map, "tt", &tt) &&
	    decode_tt(env, tt, slot));
}

/*
 * One endpoint Configure Endpoint adds, an erx_usb_claim pipe #{address, type, packet_size, burst,
 * interval_exponent, payload}. Its USB endpoint address gives its device context index, the
 * number times two plus 1 for IN (4.5.1, p. 96), a control endpoint taking the IN index as EP0
 * does; its type and that direction give the context's endpoint type. An address past a byte or
 * with its reserved bits set, or a type but control, bulk and interrupt, is badarg.
 */
static bool
decode_endpoint(ErlNifEnv *env, ERL_NIF_TERM map, erx_trb_add_t *add)
{
	erx_xhci_endpoint_context_free_t *const context = &add->context;
	ERL_NIF_TERM type;
	uint64_t address;
	bool in;

	if (!enif_is_map(env, map) || !map_u64(env, map, "address", &address) || address > UINT8_MAX ||
	    (address & ~(uint64_t)(ERX_USB_ENDPOINT_DIR_IN | ERX_USB_ENDPOINT_NUMBER_MASK)) != 0 || !map_term(env, map, "type", &type))
		return (false);
	in = (address & ERX_USB_ENDPOINT_DIR_IN) != 0;
	if (is(env, type, "control")) {
		in = true;
		context->config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL;
	} else if (is(env, type, "bulk"))
		context->config_endpoint_type = in ? ERX_XHCI_ENDPOINT_TYPE_BULK_IN : ERX_XHCI_ENDPOINT_TYPE_BULK_OUT;
	else if (is(env, type, "interrupt"))
		context->config_endpoint_type = in ? ERX_XHCI_ENDPOINT_TYPE_INTERRUPT_IN :
		    ERX_XHCI_ENDPOINT_TYPE_INTERRUPT_OUT;
	else
		return (false);
	add->dci = (uint32_t)(address & ERX_USB_ENDPOINT_NUMBER_MASK) * 2u + (in ? 1u : 0u);
	return (map_u64(env, map, "packet_size", &context->config_max_packet) &&
	    map_u64(env, map, "burst", &context->config_max_burst) &&
	    map_u64(env, map, "interval_exponent", &context->info_interval) &&
	    map_u64(env, map, "payload", &context->payload_max_esit_payload));
}

/* Configure Endpoint's `hub`: `none` for a function, or #{ports, think_time, multi_tt}, a hub's fields. */
static bool
decode_hub(ErlNifEnv *env, ERL_NIF_TERM term, erx_xhci_slot_context_free_t *slot)
{
	if (is(env, term, "none"))
		return (true);
	slot->route_hub = 1;
	return (enif_is_map(env, term) && map_u64(env, term, "ports", &slot->ports_port_count) &&
	    map_u64(env, term, "think_time", &slot->tt_tt_think_time) &&
	    map_flag(env, term, "multi_tt", &slot->route_multi_tt));
}

/* #{add, drop, hub}: at most a command's adds, and the drops as a mask of bit dci. */
static bool
decode_configure(ErlNifEnv *env, ERL_NIF_TERM map, erx_trb_command_t *command)
{
	ERL_NIF_TERM adds, drops, hub, head;
	unsigned dci;

	if (!enif_is_map(env, map) || !map_term(env, map, "add", &adds) || !map_term(env, map, "drop", &drops) ||
	    !map_term(env, map, "hub", &hub) || !decode_hub(env, hub, &command->slot_context))
		return (false);
	while (enif_get_list_cell(env, adds, &head, &adds)) {
		if (command->add_count == ERX_DMA_BINDS_MAX || !decode_endpoint(env, head, &command->adds[command->add_count]))
			return (false);
		command->add_count++;
	}
	/* The mask has a bit for each index the ring form numbers; which may drop is the form's to judge. */
	while (enif_get_list_cell(env, drops, &head, &drops)) {
		if (!enif_get_uint(env, head, &dci) || dci > ERX_DEVICE_TRB_DCI_MAX)
			return (false);
		command->drops |= UINT32_C(1) << dci;
	}
	return (enif_is_empty_list(env, adds) && enif_is_empty_list(env, drops));
}

/* The commands that name an endpoint, {Name, Slot, Dci}. */
static const struct {
	const char		*name;
	erx_trb_command_kind_t	kind;
} endpoint_commands[] = {
	{ "stop_endpoint", ERX_TRB_COMMAND_STOP_ENDPOINT },
	{ "reset_endpoint", ERX_TRB_COMMAND_RESET_ENDPOINT },
	{ "set_tr_dequeue", ERX_TRB_COMMAND_SET_TR_DEQUEUE },
};

/*
 * A command (docs/design-usb.md, "What Erlang names and what the NIF builds"): enable_slot,
 * {disable_slot, Slot}, {address_device, Slot, Map}, {evaluate_context, Slot, #{ep0_packet}},
 * {configure_endpoints, Slot, Map}, or {stop_endpoint | reset_endpoint | set_tr_dequeue, Slot, Dci}.
 * The blocks its adds take are the device's to choose (erx_trb_form_choose_blocks).
 */
static bool
decode_command(ErlNifEnv *env, ERL_NIF_TERM term, erx_trb_command_t *command)
{
	const ERL_NIF_TERM *parts;
	int arity;

	*command = (erx_trb_command_t){ .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	if (is(env, term, "enable_slot"))
		return (true);
	if (!enif_get_tuple(env, term, &arity, &parts) || arity < 2 || arity > 3 ||
	    !enif_get_uint(env, parts[1], &command->slot))
		return (false);
	if (arity == 2) {
		command->kind = ERX_TRB_COMMAND_DISABLE_SLOT;
		return (is(env, parts[0], "disable_slot"));
	}
	if (is(env, parts[0], "address_device")) {
		command->kind = ERX_TRB_COMMAND_ADDRESS_DEVICE;
		return (decode_address(env, parts[2], command));
	}
	if (is(env, parts[0], "configure_endpoints")) {
		command->kind = ERX_TRB_COMMAND_CONFIGURE_ENDPOINT;
		return (decode_configure(env, parts[2], command));
	}
	if (is(env, parts[0], "evaluate_context")) {
		ERL_NIF_TERM packet;

		command->kind = ERX_TRB_COMMAND_EVALUATE_CONTEXT;
		return (enif_is_map(env, parts[2]) && map_term(env, parts[2], "ep0_packet", &packet) &&
		    enif_get_uint(env, packet, &command->ep0_packet));
	}
	for (size_t k = 0; k < sizeof(endpoint_commands) / sizeof(endpoint_commands[0]); k++) {
		if (is(env, parts[0], endpoint_commands[k].name)) {
			command->kind = endpoint_commands[k].kind;
			return (enif_get_uint(env, parts[2], &command->dci));
		}
	}
	return (false);
}

/* A data stage or normal TRB's `{in, N}` or `{out, Bin}`; Bin's bytes stay valid for the call as a term of it. */
static bool
decode_data(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_trb_request_t *request)
{
	const ERL_NIF_TERM *pair;
	ErlNifBinary bytes;
	int arity;

	if (!enif_get_tuple(env, term, &arity, &pair) || arity != 2)
		return (false);
	request->data = true;
	if (is(env, pair[0], "in")) {
		request->device_writes = true;
		return (enif_get_uint(env, pair[1], &request->length));
	}
	if (!is(env, pair[0], "out") || !enif_inspect_binary(env, pair[1], &bytes) || bytes.size > UINT32_MAX)
		return (false);
	request->bytes = bytes.data;
	request->length = (uint32_t)bytes.size;
	return (true);
}

/*
 * A transfer: {control, Setup, none | {in, N} | {out, Bin}}, Setup exactly 8 bytes, or
 * {normal, {in, N} | {out, Bin}}. Lengths and directions are the form's to judge
 * (erx_device_trb_request_valid).
 */
static bool
decode_transfer(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_trb_request_t *request)
{
	const ERL_NIF_TERM *parts;
	ErlNifBinary setup;
	int arity;

	*request = (erx_device_trb_request_t){ .control = false };
	if (!enif_get_tuple(env, term, &arity, &parts))
		return (false);
	if (arity == 2 && is(env, parts[0], "normal"))
		return (decode_data(env, parts[1], request));
	if (arity != 3 || !is(env, parts[0], "control") || !enif_inspect_binary(env, parts[1], &setup) ||
	    setup.size != sizeof(request->setup))
		return (false);
	request->control = true;
	bcopy(setup.data, request->setup, sizeof(request->setup));
	return (is(env, parts[2], "none") || decode_data(env, parts[2], request));
}

/*
 * A post's answer (docs/design-usb.md, "Refusals and error results"): ok, the form's refusals as
 * badarg, {error, full} and {error, halted}, and the call's own status, {error, einval} for a
 * device that is not a started xHCI controller's record and {error, broken} for a broken form.
 */
static ERL_NIF_TERM
trb_posted(ErlNifEnv *env, int status, erx_device_trb_verdict_t verdict)
{
	if (status != ERX_OK)
		return (status_error(env, status));
	switch (verdict) {
	case ERX_DEVICE_TRB_ACCEPTED:
		return (enif_make_atom(env, "ok"));
	case ERX_DEVICE_TRB_REFUSE_FULL:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "full")));
	case ERX_DEVICE_TRB_REFUSE_HALTED:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "halted")));
	case ERX_DEVICE_TRB_REFUSE_BADARG:
	default:
		return (enif_make_badarg(env));
	}
}

/* post(Dev, command, Tag, Command) or post(Dev, {Slot, Dci}, Tag, Transfer) */
static ERL_NIF_TERM
trb_post(ErlNifEnv *env, const erx_device_t *device, const ERL_NIF_TERM argv[])
{
	const ERL_NIF_TERM *pipe;
	erx_trb_command_t command;
	erx_device_trb_request_t request;
	erx_device_trb_verdict_t verdict = ERX_DEVICE_TRB_REFUSE_BADARG;
	ErlNifUInt64 tag;
	uint32_t slot, dci;
	int arity, status;

	if (!enif_get_uint64(env, argv[2], &tag))
		return (enif_make_badarg(env));
	if (is(env, argv[1], "command")) {
		if (!decode_command(env, argv[3], &command))
			return (enif_make_badarg(env));
		enif_mutex_lock(device_lock);
		status = erx_device_trb_command(device, &command, tag, &verdict);
		enif_mutex_unlock(device_lock);
		return (trb_posted(env, status, verdict));
	}
	if (!enif_get_tuple(env, argv[1], &arity, &pipe) || arity != 2 || !enif_get_uint(env, pipe[0], &slot) ||
	    !enif_get_uint(env, pipe[1], &dci) || !decode_transfer(env, argv[3], &request))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_trb_post(device, slot, dci, tag, &request, &verdict);
	enif_mutex_unlock(device_lock);
	return (trb_posted(env, status, verdict));
}

/* post(Dev, Q, Tag, Segments) on a queue, or a TRB form post */
static ERL_NIF_TERM
post_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);

	if (device == NULL)
		return (enif_make_badarg(env));
	return (enif_is_number(env, argv[1]) ? queue_post(env, argc, argv) : trb_post(env, device, argv));
}

/*
 * What trb_complete collects, in the form's order: each answer, and the bytes it carries in a
 * fresh binary of their length, so no term ever aliases memory the device can write, read only
 * once the call has copied them: a transfer's bytes moved, or an Address Device's output slot
 * context.
 */
typedef struct trb_answers {
	ErlNifEnv		*env;
	uint32_t		count;
	erx_trb_answer_t	answers[ERX_TRB_FORM_ANSWERS_MAX(ERX_DEVICE_COMPLETE_ENTRIES)];
	ERL_NIF_TERM		bytes[ERX_TRB_FORM_ANSWERS_MAX(ERX_DEVICE_COMPLETE_ENTRIES)];
} trb_answers_t;

static uint8_t *
trb_answer_sink(void *context, const erx_trb_answer_t *answer)
{
	trb_answers_t *const collected = context;
	const uint32_t at = collected->count++;

	collected->answers[at] = *answer;
	return (enif_make_new_binary(collected->env, answer->data.length, &collected->bytes[at]));
}

/*
 * One answer as erx_xhci takes it: a transfer's {Tag, Code, Bytes}; a command's {Tag, Code, Extra},
 * Extra the address the controller wrote in the slot's output context for an Address Device's
 * success, which Erlang bounds, as it is the controller's, and the event's slot otherwise; a
 * port's event {port, Port}.
 */
static ERL_NIF_TERM
trb_answer_term(ErlNifEnv *env, const trb_answers_t *collected, uint32_t at)
{
	const erx_trb_answer_t *const answer = &collected->answers[at];
	erx_xhci_slot_context_t context;
	ErlNifBinary carried;
	ERL_NIF_TERM extra = collected->bytes[at];

	switch (answer->kind) {
	case ERX_TRB_ANSWER_TRANSFER:
		break;
	case ERX_TRB_ANSWER_COMMAND:
		/* Only an Address Device's success carries bytes, its output slot context. */
		if (enif_inspect_binary(env, extra, &carried) && carried.size == sizeof(context)) {
			bcopy(carried.data, &context, sizeof(context));
			extra = enif_make_uint(env, erx_xhci_slot_context_state_address_get(context.state));
		} else
			extra = enif_make_uint(env, answer->slot);
		break;
	case ERX_TRB_ANSWER_PORT:
		return (enif_make_tuple2(env, enif_make_atom(env, "port"), enif_make_uint(env, answer->port)));
	}
	return (enif_make_tuple3(env, enif_make_uint64(env, answer->tag), enif_make_uint(env, answer->code), extra));
}

/* complete(Dev, events): what the controller has reported, in the form's order */
static ERL_NIF_TERM
trb_complete(ErlNifEnv *env, const erx_device_t *device)
{
	static trb_answers_t collected;
	ERL_NIF_TERM terms[ERX_TRB_FORM_ANSWERS_MAX(ERX_DEVICE_COMPLETE_ENTRIES)];
	uint32_t count;
	int status;

	enif_mutex_lock(device_lock);
	collected.env = env;
	collected.count = 0;
	status = erx_device_trb_complete(device, trb_answer_sink, &collected, &count);
	for (uint32_t at = 0; status == ERX_OK && at < count; at++)
		terms[at] = trb_answer_term(env, &collected, at);
	enif_mutex_unlock(device_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_list_from_array(env, terms, count)));
}

/* complete(Dev, Q) on a queue, or complete(Dev, events) on the TRB form's event ring */
static ERL_NIF_TERM
complete_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);

	if (device == NULL)
		return (enif_make_badarg(env));
	if (enif_is_number(env, argv[1]))
		return (queue_complete(env, argc, argv));
	return (is(env, argv[1], "events") ? trb_complete(env, device) : enif_make_badarg(env));
}

/* queue_state(Dev, {Slot, Dci}): idle, busy, stopped or halted; badarg for a pair that names no queue */
static ERL_NIF_TERM
queue_state_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	static const char *const names[] = {
		[ERX_TRB_QUEUE_IDLE] = "idle", [ERX_TRB_QUEUE_BUSY] = "busy",
		[ERX_TRB_QUEUE_STOPPED] = "stopped", [ERX_TRB_QUEUE_HALTED] = "halted",
	};
	const erx_device_t *const device = device_of(env, argv[0]);
	const ERL_NIF_TERM *pipe;
	erx_trb_queue_state_t state = ERX_TRB_QUEUE_NONE;
	uint32_t slot, dci;
	int arity, status;

	(void)argc;
	if (device == NULL || !enif_get_tuple(env, argv[1], &arity, &pipe) || arity != 2 ||
	    !enif_get_uint(env, pipe[0], &slot) || !enif_get_uint(env, pipe[1], &dci))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_trb_queue_state(device, slot, dci, &state);
	enif_mutex_unlock(device_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	if (state == ERX_TRB_QUEUE_NONE || (size_t)state >= sizeof(names) / sizeof(names[0]))
		return (enif_make_badarg(env));
	return (enif_make_atom(env, names[state]));
}

#ifdef ERX_DEVICE_STAND_IN
/* Fires a hosted stand-in's line, as a device would. A native build has no such NIF. */
static ERL_NIF_TERM
stand_in_fire_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned device_index, line_index;
	const erx_device_t *device;
	uint64_t irq;

	(void)argc;
	if (!enif_get_uint(env, argv[0], &device_index) || !enif_get_uint(env, argv[1], &line_index))
		return (enif_make_badarg(env));
	device = erx_device_get(device_index);
	if (device == NULL || !erx_device_line_irq(device, line_index, &irq) || erx_irq_trigger(irq) != ERX_OK)
		return (enif_make_badarg(env));
	return (enif_make_atom(env, "ok"));
}

/* One `{next, Length}` or `{Id, Length}` of stand_in_used/3. */
static bool
decode_used_entry(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_used_entry_t *entry)
{
	const ERL_NIF_TERM *pair;
	unsigned id = 0, length;
	int arity;

	if (!enif_get_tuple(env, term, &arity, &pair) || arity != 2 || !enif_get_uint(env, pair[1], &length))
		return (false);
	entry->next = enif_is_identical(pair[0], enif_make_atom(env, "next"));
	if (!entry->next && !enif_get_uint(env, pair[0], &id))
		return (false);
	entry->id = id;
	entry->length = length;
	return (true);
}

/* stand_in_used(Dev, Q, Entries): a hosted stand-in's device returns entries on a queue, honest or not. */
static ERL_NIF_TERM
stand_in_used_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	erx_device_used_entry_t entries[ERX_DEVICE_QUEUE_SIZE_MAX];
	ERL_NIF_TERM list = argv[2], head;
	unsigned queue, count = 0;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &queue))
		return (enif_make_badarg(env));
	while (enif_get_list_cell(env, list, &head, &list)) {
		if (count == ERX_DEVICE_QUEUE_SIZE_MAX || !decode_used_entry(env, head, &entries[count]))
			return (enif_make_badarg(env));
		count++;
	}
	if (!enif_is_empty_list(env, list))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_stand_in_used(device, queue, entries, count);
	enif_mutex_unlock(device_lock);
	return (status == ERX_OK ? enif_make_atom(env, "ok") : enif_make_badarg(env));
}

/* The engine sends at most a ring's worth, which `terms` holds. */
_Static_assert(ERX_GENET_RING_SIZE <= ERX_DEVICE_QUEUE_SIZE_MAX, "a GENET ring's frames fit completions_t");

/* A fresh binary for each frame a stand-in GENET sends, so no term aliases the queue memory. */
static uint8_t *
frame_sink(void *context, uint64_t tag, uint32_t length)
{
	completions_t *const frames = context;
	uint8_t *const bytes = enif_make_new_binary(frames->env, length, &frames->terms[frames->count]);

	(void)tag;
	frames->count++;
	return (bytes);
}

/* stand_in_transmitted(Dev): the frames a stand-in GENET sends, oldest first. */
static ERL_NIF_TERM
stand_in_transmitted_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	completions_t frames = { .env = env };
	uint32_t sent;
	int status;

	(void)argc;
	if (device == NULL)
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_stand_in_transmitted(device, frame_sink, &frames, &sent);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_list_from_array(env, frames.terms, sent));
}

/*
 * stand_in_receive(Dev, Frames): how many of Frames a stand-in GENET takes into its receive
 * ring, from the front. A ring holds no more than its size, so the frames past that are not read.
 */
static ERL_NIF_TERM
stand_in_receive_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	erx_device_frame_t frames[ERX_DEVICE_QUEUE_SIZE_MAX];
	ERL_NIF_TERM list = argv[1], head;
	ErlNifBinary binary;
	uint32_t count = 0, taken;
	int status;

	(void)argc;
	if (device == NULL)
		return (enif_make_badarg(env));
	while (count < ERX_GENET_RING_SIZE && enif_get_list_cell(env, list, &head, &list)) {
		if (!enif_inspect_binary(env, head, &binary) || binary.size > UINT32_MAX)
			return (enif_make_badarg(env));
		frames[count++] = (erx_device_frame_t){ .bytes = binary.data, .length = (uint32_t)binary.size };
	}
	if (count < ERX_GENET_RING_SIZE && !enif_is_empty_list(env, list))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_stand_in_receive(device, frames, count, &taken);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_uint(env, taken));
}
#endif

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	static const ErlNifResourceTypeInit binding_init = { .down = binding_down, .members = 3 };

	(void)priv;
	(void)info;
	device_lock = enif_mutex_create("erx_device");
	binding_type = enif_init_resource_type(env, "erx_device_binding", &binding_init, ERL_NIF_RT_CREATE, NULL);
	return (device_lock == NULL || binding_type == NULL ? 1 : 0);
}

static ErlNifFunc nif_funcs[] = {
	{ "open", 1, open_nif, 0 },
	{ "elements", 2, elements_nif, 0 },
	{ "config_read", 4, config_read_nif, 0 },
	{ "config_write", 5, config_write_nif, 0 },
	{ "irq_bind", 2, irq_bind_nif, 0 },
	{ "irq_bind_owner", 2, irq_bind_owner_nif, 0 },
	{ "irq_holder", 2, irq_holder_nif, 0 },
	{ "queue_create", 4, queue_create_nif, 0 },
	{ "region", 3, region_nif, 0 },
	{ "framebuffer", 0, framebuffer_nif, 0 },
	{ "negotiate", 2, negotiate_nif, 0 },
	{ "post", 4, post_nif, 0 },
	{ "complete", 2, complete_nif, 0 },
	{ "queue_state", 2, queue_state_nif, 0 },
#ifdef ERX_DEVICE_STAND_IN
	{ "stand_in_fire", 2, stand_in_fire_nif, 0 },
	{ "stand_in_used", 3, stand_in_used_nif, 0 },
	{ "stand_in_transmitted", 1, stand_in_transmitted_nif, 0 },
	{ "stand_in_receive", 2, stand_in_receive_nif, 0 },
#endif
};

ERL_NIF_INIT(erx_device, nif_funcs, load, NULL, NULL, NULL)
