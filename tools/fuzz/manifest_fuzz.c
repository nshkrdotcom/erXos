/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The system manifest's generated C reader, which the root runs at boot over the
 * archive's manifest entry. What the reader accepts must keep every table in reach:
 * each row its header counts reads back, and the row one past the end does not.
 * The domain library's boot view (liberx/system/dom_boot_view.c) then reads every
 * manifest the reader accepts, as the root does next, and what it admits must keep
 * the placement, string and boot timeout rules it exists for (view_check).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi_reader.h"
#include "erx/dom_lib.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/*
 * Reads a table's rows. A row within the count that does not read back means the reader
 * accepted a table it cannot serve, and so does a row past the count that does.
 */
#define MANIFEST_TABLE(view, table, type)					\
	do {									\
		type row;							\
										\
		for (size_t index = 0; index < (view)->header.table.count; index++) \
			if (!erx_manifest_##table##_at((view), index, &row))	\
				abort();					\
		if (erx_manifest_##table##_at((view), (view)->header.table.count, &row)) \
			abort();						\
	} while (0)

/* The tables a view of a manifest larger than this needs are not worth a run. */
#define VIEW_TABLES_MAX	((size_t)64 << 20)

/*
 * Whether the view admitted facet's grantee as the boot may grant it: the
 * system domain, with index 0, for a configured domain's service; a
 * configured row other than the server; or a session template, of any
 * service (property 14): a configured domain's, which the server grants
 * each session, or the system domain's, whose facet the domain service
 * starts for each session.
 */
static bool
grantee_admitted(const erx_dom_view_t *dom, const erx_dom_facet_t *facet)
{
	uint32_t server = dom->services[facet->service].server;

	switch (facet->grantee_kind) {
	case ERX_MF_GRANTEE_SYSTEM:
		return (facet->grantee == 0 && server != ERX_MF_NONE);
	case ERX_MF_GRANTEE_DOMAIN:
		return (facet->grantee < dom->nconfigured && facet->grantee != server);
	case ERX_MF_GRANTEE_SESSION:
		return (facet->grantee < dom->ntemplates);
	default:
		return (false);
	}
}

/*
 * Whether parameter is one of the ndeclared declarations at declared. Each
 * file that reads erx_service_parameters has its own copy of the table, so
 * the declaration is matched by its fields, not by its address.
 */
static bool
declares(const erx_service_parameter_t *declared, size_t ndeclared, const erx_service_parameter_t *parameter)
{
	for (size_t index = 0; index < ndeclared; index++)
		if (declared[index].interface == parameter->interface && declared[index].number == parameter->number &&
		    declared[index].kind == parameter->kind && declared[index].required == parameter->required &&
		    declared[index].minimum == parameter->minimum && declared[index].maximum == parameter->maximum &&
		    strcmp(declared[index].name, parameter->name) == 0)
			return (true);
	return (false);
}

/*
 * Whether the view carries facet row facet_row's operations as facet's, each
 * of them: one per row, so none is dropped; each the declaration of its
 * row's number, so none is mapped to another; each a declaration of the
 * service's interface, matched by its fields as declares does, in strictly
 * ascending number order, so none is named twice; and none for a service a
 * configured domain serves, whose server checks none on the stopgap.
 */
static bool
operations_admitted(const erx_manifest_view_t *view, const erx_dom_view_t *dom, const erx_dom_facet_t *facet,
    const erx_mf_facet_t *facet_row)
{
	const uint32_t first = (facet_row->operations.offset - view->header.facet_operations.offset) / ERX_MF_OPERATION_SIZE;
	const erx_service_operation_t *declared, *operation;
	erx_mf_operation_t row;
	size_t ndeclared;
	bool found;

	declared = erx_service_operations(dom->services[facet->service].interface, &ndeclared);
	if (facet->noperations != facet_row->operations.count ||
	    (facet->noperations != 0 && dom->services[facet->service].server != ERX_MF_NONE))
		return (false);
	for (uint32_t index = 0; index < facet->noperations; index++) {
		operation = facet->operations[index];
		if (!erx_manifest_facet_operations_at(view, first + index, &row) || row.operation != operation->number)
			return (false);
		found = false;
		for (size_t at = 0; at < ndeclared; at++)
			found |= declared[at].interface == operation->interface && declared[at].number == operation->number &&
			    strcmp(declared[at].name, operation->name) == 0;
		if (!found || (index > 0 && operation->number <= facet->operations[index - 1]->number))
			return (false);
	}
	return (true);
}

/*
 * Whether the view carries facet row facet_row's parameters as facet's, each
 * of them: one per row, so none is dropped; each a declaration of the
 * service's interface, in strictly ascending number order, so none is
 * stated twice; of a kind the boot carries and within its declared bound,
 * a device reference a row of the view's devices; and with every
 * declaration the interface requires among them.
 */
static bool
parameters_admitted(const erx_dom_view_t *dom, const erx_dom_facet_t *facet, const erx_mf_facet_t *facet_row)
{
	const erx_service_parameter_t *declared, *parameter;
	const erx_dom_parameter_t *value;
	size_t ndeclared, required = 0, stated = 0;
	bool within;

	declared = erx_service_parameters(dom->services[facet->service].interface, &ndeclared);
	if (facet->nparameters != facet_row->parameters.count)
		return (false);
	for (size_t index = 0; index < ndeclared; index++)
		required += declared[index].required;
	for (uint32_t index = 0; index < facet->nparameters; index++) {
		value = &facet->parameters[index];
		parameter = value->declared;
		if (!declares(declared, ndeclared, parameter) ||
		    (index > 0 && parameter->number <= facet->parameters[index - 1].declared->number))
			return (false);
		stated += parameter->required;
		switch (parameter->kind) {
		case ERX_MF_PARAMETER_U64:
		case ERX_MF_PARAMETER_BOOLEAN:
			within = value->scalar >= parameter->minimum && value->scalar <= parameter->maximum;
			break;
		case ERX_MF_PARAMETER_MEMBER:
			/* The NIF names it members[scalar - minimum]. */
			within = parameter->members != NULL && value->scalar >= parameter->minimum &&
			    value->scalar <= parameter->maximum;
			break;
		case ERX_MF_PARAMETER_I64:
			within = (int64_t)value->scalar >= (int64_t)parameter->minimum &&
			    (int64_t)value->scalar <= (int64_t)parameter->maximum;
			break;
		case ERX_MF_PARAMETER_IDENTIFIER:
		case ERX_MF_PARAMETER_NAMESPACE_PATH:
		case ERX_MF_PARAMETER_BYTES:
			within = value->bytes != NULL && value->bytes_len <= parameter->maximum;
			break;
		case ERX_MF_PARAMETER_DEVICE:
			within = value->index < dom->ndevices;
			break;
		default:
			within = false;
		}
		if (!within)
			return (false);
	}
	return (stated == required);
}

/*
 * What a view the library admits holds: an entry per device row, each in one
 * unit and on that unit's holder, with a record of its own index; no two units
 * on one register page; each configured row's words with room for both
 * node names; and every service and facet row, each server a configured row
 * or the system domain and each grantee one the boot may grant (grantee_admitted),
 * no grantee taking two facets of one service name, and each facet's
 * operations (operations_admitted) and parameters (parameters_admitted) its
 * service's.
 */
static void
view_check(const erx_manifest_view_t *view, const erx_dom_lib_t *lib)
{
	const erx_dom_view_t *dom = &lib->view;
	const erx_dom_device_entry_t *a, *b;
	const erx_dom_configured_t *row;
	const erx_dom_facet_t *facet;
	const erx_dom_service_t *a_service, *b_service;
	erx_mf_facet_t facet_row;
	erx_mf_unit_t unit;

	if (dom->ndevices != view->header.devices.count ||
	    dom->nservices != view->header.services.count || dom->nfacets != view->header.facets.count)
		abort();
	for (uint32_t index = 0; index < dom->nservices; index++)
		if (dom->services[index].server != ERX_MF_NONE && dom->services[index].server >= dom->nconfigured)
			abort();
	for (uint32_t index = 0; index < dom->nfacets; index++) {
		facet = &dom->facets[index];
		if (!erx_manifest_facets_at(view, index, &facet_row) || facet->service >= dom->nservices ||
		    !grantee_admitted(dom, facet) || !operations_admitted(view, dom, facet, &facet_row) ||
		    !parameters_admitted(dom, facet, &facet_row))
			abort();
		for (uint32_t earlier = 0; earlier < index; earlier++) {
			a_service = &dom->services[dom->facets[earlier].service];
			b_service = &dom->services[facet->service];
			if (dom->facets[earlier].grantee_kind == facet->grantee_kind &&
			    dom->facets[earlier].grantee == facet->grantee && a_service->name_len == b_service->name_len &&
			    memcmp(a_service->name, b_service->name, b_service->name_len) == 0)
				abort();
		}
	}
	for (uint32_t index = 0; index < dom->ndevices; index++) {
		a = &dom->devices[index];
		if (!erx_manifest_units_at(view, a->unit, &unit) || unit.holder != a->row ||
		    dom->device_records[index].index != index || a->nranges > 1 || a->confined)
			abort();
		for (uint32_t other = index + 1; other < dom->ndevices; other++) {
			b = &dom->devices[other];
			if (a->unit != b->unit && a->nranges != 0 && b->nranges != 0 &&
			    a->ranges[0].base < b->ranges[0].base + b->ranges[0].size &&
			    b->ranges[0].base < a->ranges[0].base + a->ranges[0].size)
				abort();
		}
	}
	for (uint32_t index = 0; index < dom->nconfigured; index++) {
		row = &dom->configured[index];
		if ((uint64_t)row->args_len + row->env_len + 2u * ERX_DOM_NODE_MAX > ERX_BOOT_STRINGS_MAX)
			abort();
		/* The domain service makes it milliseconds of an Erlang timer. */
		if (row->boot_timeout_s < 1 || row->boot_timeout_s > ERX_BOOT_TIMEOUT_MAX_S)
			abort();
	}
}

/* The library's view of an accepted manifest, in tables laid out as the root lays them. */
static void
view_build(const erx_manifest_view_t *view)
{
	const erx_dom_boot_sizes_t sizes = erx_dom_view_sizes(view, 0);
	erx_dom_boot_tables_t tables;
	erx_dom_lib_t lib;
	size_t bytes;
	void *region;

	if (!erx_dom_boot_layout(&sizes, 0, &tables, &bytes) || bytes > VIEW_TABLES_MAX)
		return;
	if ((region = calloc(1, bytes == 0 ? 1 : bytes)) == NULL)
		return;
	if (!erx_dom_boot_layout(&sizes, (uintptr_t)region, &tables, &bytes))
		abort();
	if (erx_dom_view_build(&lib, view, 0, &tables) == NULL)
		view_check(view, &lib);
	free(region);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_manifest_view_t view;
	erx_abi_error_t error = { 0 };

	if (!erx_manifest_open(data, size, &view, &error)) {
		if (error.reason == NULL || error.field == NULL)
			abort();
		return (0);
	}
	MANIFEST_TABLE(&view, principals, erx_mf_principal_t);
	MANIFEST_TABLE(&view, domains, erx_mf_domain_t);
	MANIFEST_TABLE(&view, sessions, erx_mf_session_t);
	MANIFEST_TABLE(&view, limits, erx_mf_limits_t);
	MANIFEST_TABLE(&view, runtime_limits, erx_mf_runtime_limits_t);
	MANIFEST_TABLE(&view, lane_classes, erx_mf_lane_class_t);
	MANIFEST_TABLE(&view, units, erx_mf_unit_t);
	MANIFEST_TABLE(&view, devices, erx_mf_device_t);
	MANIFEST_TABLE(&view, windows, erx_mf_window_t);
	MANIFEST_TABLE(&view, services, erx_mf_service_t);
	MANIFEST_TABLE(&view, facets, erx_mf_facet_t);
	MANIFEST_TABLE(&view, facet_operations, erx_mf_operation_t);
	MANIFEST_TABLE(&view, facet_parameters, erx_mf_parameter_t);
	MANIFEST_TABLE(&view, introductions, erx_mf_introduction_t);
	MANIFEST_TABLE(&view, images, erx_mf_image_t);
	MANIFEST_TABLE(&view, extents, erx_mf_extent_t);
	MANIFEST_TABLE(&view, boot_order, erx_mf_boot_order_t);
	MANIFEST_TABLE(&view, liveness, erx_mf_liveness_t);
	MANIFEST_TABLE(&view, shell_principals, erx_mf_shell_principal_t);
	MANIFEST_TABLE(&view, partial_boot, erx_mf_partial_boot_t);
	MANIFEST_TABLE(&view, starts, erx_mf_start_t);
	MANIFEST_TABLE(&view, displays, erx_mf_display_t);
	view_build(&view);
	return (0);
}
