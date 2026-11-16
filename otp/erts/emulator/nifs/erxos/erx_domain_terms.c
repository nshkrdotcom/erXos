/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The services and facet rows of the domain library's view as the terms
 * the domain service reads (erx_domain_terms.h).
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "erl_nif.h"

#include "erx/abi.h"
#include "erx/dom.h"
#include "erx_domain_terms.h"

static ERL_NIF_TERM
atom(ErlNifEnv *env, const char *name)
{
	return (enif_make_atom(env, name));
}

/*
 * A checked parameter's value: an integer kind's as an integer, a
 * boolean as true or false, text or bytes as a binary, a member as the
 * atom of its name, one the ABI declares, which the view has checked lies
 * within its members (boot_parameter), and a device reference as its
 * device row's index.
 */
static bool
parameter_term(ErlNifEnv *env, const erx_dom_parameter_t *parameter, ERL_NIF_TERM *value)
{
	unsigned char *bytes;

	switch (parameter->declared->kind) {
	case ERX_MF_PARAMETER_U64:
		*value = enif_make_uint64(env, parameter->scalar);
		return (true);
	case ERX_MF_PARAMETER_I64:
		*value = enif_make_int64(env, (int64_t)parameter->scalar);
		return (true);
	case ERX_MF_PARAMETER_BOOLEAN:
		*value = atom(env, parameter->scalar != 0 ? "true" : "false");
		return (true);
	case ERX_MF_PARAMETER_MEMBER:
		*value = atom(env, parameter->declared->members[parameter->scalar - parameter->declared->minimum]);
		return (true);
	case ERX_MF_PARAMETER_IDENTIFIER:
	case ERX_MF_PARAMETER_NAMESPACE_PATH:
	case ERX_MF_PARAMETER_BYTES:
		if ((bytes = enif_make_new_binary(env, parameter->bytes_len, value)) == NULL)
			return (false);
		if (parameter->bytes_len != 0)
			memcpy(bytes, parameter->bytes, parameter->bytes_len);
		return (true);
	case ERX_MF_PARAMETER_DEVICE:
		*value = enif_make_uint(env, parameter->index);
		return (true);
	default:
		return (false);
	}
}

/* A configured row, or for ERX_MF_NONE the system domain, as the atom system. */
static ERL_NIF_TERM
server_term(ErlNifEnv *env, uint32_t server)
{
	return (server == ERX_MF_NONE ? atom(env, "system") : enif_make_uint(env, server));
}

/*
 * The services, [{Server, Name, Interface}], Server a configured domain's
 * row or, for a service the system domain serves, the atom system,
 * Interface the abi/services number of the interface it serves (an
 * ERX_SERVICE_* value), and the facet
 * rows, [{Grantee, Name, Server, Limits}], Grantee a configured row, the
 * atom system, or {template, Template} for the sessions made from session
 * template Template, the index a session's origin {session, Template}
 * names, Name the service's name as an atom, Server its server's row
 * or, for a service the system domain serves, the atom system, and Limits
 * the grant's limits by name: the facet row's six limit fields and each
 * parameter it states, under its declared name (parameter_term), which
 * the ABI generator keeps apart from the fields' names; each list in
 * manifest order
 * (docs/design-system.md, "Facets a configured domain serves"). The
 * domain service hands only the configured domains' services to its mint
 * core, and reads the system domain's for their interface.
 * A name is a checked identifier of at most 63 bytes from the manifest,
 * never from a request, and a parameter's name is the ABI's, so the atoms
 * are bounded by the manifest's rows and the ABI's declarations.
 */
bool
erx_domain_served_terms(ErlNifEnv *env, const erx_dom_view_t *view, ERL_NIF_TERM *services, ERL_NIF_TERM *grants)
{
	/* The facet row's six limit fields and at most one parameter a declaration (boot_facet_parameters). */
	ERL_NIF_TERM keys[6 + ERX_SERVICE_PARAMETERS_MAX], values[6 + ERX_SERVICE_PARAMETERS_MAX];
	ERL_NIF_TERM limits, grantee, name;
	const erx_dom_service_t *service;
	const erx_dom_facet_t *facet;
	uint32_t index, nkeys;

	/* Each list built from the last row back, so its head is the first row. */
	*services = enif_make_list(env, 0);
	for (index = view->nservices; index-- > 0;) {
		service = &view->services[index];
		name = enif_make_atom_len(env, service->name, service->name_len);
		*services = enif_make_list_cell(env, enif_make_tuple3(env, server_term(env, service->server), name,
		    enif_make_uint(env, service->interface)), *services);
	}
	*grants = enif_make_list(env, 0);
	for (index = view->nfacets; index-- > 0;) {
		facet = &view->facets[index];
		service = &view->services[facet->service];
		nkeys = 0;
		keys[nkeys] = atom(env, "max_request"), values[nkeys++] = enif_make_uint(env, facet->max_request);
		keys[nkeys] = atom(env, "in_flight"), values[nkeys++] = enif_make_uint(env, facet->in_flight);
		keys[nkeys] = atom(env, "reductions"), values[nkeys++] = enif_make_uint64(env, facet->reductions);
		keys[nkeys] = atom(env, "period_ns"), values[nkeys++] = enif_make_uint64(env, facet->period_ns);
		keys[nkeys] = atom(env, "max_heap_size"), values[nkeys++] = enif_make_uint64(env, facet->max_heap_size);
		keys[nkeys] = atom(env, "queue"), values[nkeys++] = enif_make_uint64(env, facet->queue);
		/* The view states each parameter once, so at most ERX_SERVICE_PARAMETERS_MAX of them. */
		if (facet->nparameters > sizeof(keys) / sizeof(keys[0]) - nkeys)
			return (false);
		for (uint32_t at = 0; at < facet->nparameters; at++) {
			keys[nkeys] = atom(env, facet->parameters[at].declared->name);
			if (!parameter_term(env, &facet->parameters[at], &values[nkeys++]))
				return (false);
		}
		if (!enif_make_map_from_arrays(env, keys, values, nkeys, &limits))
			return (false);
		switch (facet->grantee_kind) {
		case ERX_MF_GRANTEE_DOMAIN:
			grantee = enif_make_uint(env, facet->grantee);
			break;
		case ERX_MF_GRANTEE_SESSION:
			grantee = enif_make_tuple2(env, atom(env, "template"), enif_make_uint(env, facet->grantee));
			break;
		case ERX_MF_GRANTEE_SYSTEM:
			grantee = atom(env, "system");
			break;
		default:
			return (false);
		}
		name = enif_make_atom_len(env, service->name, service->name_len);
		*grants = enif_make_list_cell(env, enif_make_tuple4(env, grantee, name, server_term(env, service->server),
		    limits), *grants);
	}
	return (true);
}
