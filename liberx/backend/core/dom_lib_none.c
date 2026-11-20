/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library where none is built. The library is the system domain's
 * alone (docs/design-system.md, "The domain library"), and only the native
 * root links it. A domain's runtime and a hosted runtime link the
 * erx_domain_lib NIF module like the system domain's ERTS and link this in the
 * library's place: erx_dom_lib_system finds no library, so the module loads inert and
 * answers {error, enotsup} (erlang/apps/erx/src/erx_domain_lib.erl).
 * Only erx_dom_lib_system is ever called; the rest answer ERX_ENOTSUP so the
 * link resolves.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/dom_lib.h"

erx_dom_lib_t *
erx_dom_lib_system(void)
{
	return (NULL);
}

erx_status_t
erx_dom_lib_create(erx_dom_lib_t *lib, const erx_dom_spec_t *req, const erx_runtime_limits_t *limits,
    uint32_t given, erx_dom_created_t *created)
{
	(void)lib, (void)req, (void)limits, (void)given, (void)created;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_configured(erx_dom_lib_t *lib, uint32_t id, uint32_t row, erx_dom_pid_t domain_pid,
    erx_dom_created_t *created)
{
	(void)lib, (void)id, (void)row, (void)domain_pid, (void)created;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_session(erx_dom_lib_t *lib, uint32_t id, uint32_t template, const char *name, uint32_t name_len,
    const char *display, uint32_t display_len, erx_dom_pid_t domain_pid, erx_dom_created_t *created)
{
	(void)lib, (void)id, (void)template, (void)name, (void)name_len, (void)display, (void)display_len;
	(void)domain_pid, (void)created;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_app_session(erx_dom_lib_t *lib, uint32_t id, uint32_t entry, uint64_t memory, const char *name,
    uint32_t name_len, const char *display, uint32_t display_len, erx_dom_pid_t domain_pid,
    erx_dom_created_t *created)
{
	(void)lib, (void)id, (void)entry, (void)memory, (void)name, (void)name_len, (void)display;
	(void)display_len, (void)domain_pid, (void)created;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_start(erx_dom_lib_t *lib, uint32_t id)
{
	(void)lib, (void)id;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_stop(erx_dom_lib_t *lib, uint32_t id, int64_t status)
{
	(void)lib, (void)id, (void)status;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_connect(erx_dom_lib_t *lib, uint32_t a, uint32_t b, uint32_t a_reads, uint32_t b_reads,
    uint64_t area, uint32_t area_reader,
    erx_dom_linked_t *linked)
{
	(void)lib, (void)a, (void)b, (void)a_reads, (void)b_reads, (void)area, (void)area_reader, (void)linked;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_disconnect(erx_dom_lib_t *lib, uint32_t number)
{
	(void)lib, (void)number;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_retire(erx_dom_lib_t *lib, uint32_t id)
{
	(void)lib, (void)id;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_code_object(erx_dom_lib_t *lib, uint32_t id, uint64_t size, uint32_t *number, uint64_t *value)
{
	(void)lib, (void)id, (void)size, (void)number, (void)value;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_code_drop(erx_dom_lib_t *lib, uint32_t id, uint32_t number)
{
	(void)lib, (void)id, (void)number;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_crash_copy(erx_dom_lib_t *lib, uint32_t id, uint64_t dst)
{
	(void)lib, (void)id, (void)dst;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_info(erx_dom_lib_t *lib, uint32_t id, uint32_t topic, void *window, uint64_t size)
{
	(void)lib, (void)id, (void)topic, (void)window, (void)size;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_take(uint64_t wait_by, uint64_t *label, erx_fault_t *record)
{
	(void)wait_by, (void)label, (void)record;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_end_commit(erx_dom_lib_t *lib, uint32_t how)
{
	(void)lib, (void)how;
	return (ERX_ENOTSUP);
}

bool
erx_dom_lib_record(erx_dom_lib_t *lib, uint64_t label, const erx_fault_t *record, erx_dom_report_t *report)
{
	(void)lib, (void)label, (void)record, (void)report;
	return (false);
}

erx_status_t
erx_dom_lib_pci_report(erx_dom_lib_t *lib, uint32_t bridge, const erx_dom_pci_record_t *records, uint32_t count,
    erx_dom_pci_refusal_t *refusal)
{
	(void)lib, (void)bridge, (void)records, (void)count, (void)refusal;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_pci_mode(erx_dom_lib_t *lib, uint32_t index, uint32_t mode)
{
	(void)lib, (void)index, (void)mode;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_pci_answered(erx_dom_lib_t *lib, uint32_t domain)
{
	(void)lib, (void)domain;
	return (ERX_ENOTSUP);
}
