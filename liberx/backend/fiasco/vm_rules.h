/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_VM_RULES_H
#define ERX_FIASCO_VM_RULES_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * What the root service may do with a memory object: the pure decisions behind vm.c's
 * maps, copies and supplies and the service's create of a paged object
 * (docs/design-stopgap.md, "The call table"). They read only the object's traits and
 * the request, so the host checks them (test/fixtures/fiasco_vm_driver.c), and vm.c
 * acts only on ERX_OK.
 */

typedef enum erx_fiasco_vm_kind {
	ERX_FIASCO_VM_PAGES,		/* pool pages, erx_mem_create's */
	ERX_FIASCO_VM_PHYSICAL,		/* a device's registers */
	ERX_FIASCO_VM_CONTIGUOUS,	/* a run of the contiguous pool, which a device may write */
	ERX_FIASCO_VM_SLICE,		/* the boot archive's own pages, which nothing writes */
	ERX_FIASCO_VM_PAGED		/* pool pages filled by supplies until sealed, then never written */
} erx_fiasco_vm_kind_t;

typedef struct erx_fiasco_vm_traits {
	erx_fiasco_vm_kind_t	kind;
	/*
	 * Its pages may run: a slice's an image entry's, through erx_fiasco_vm_image_map
	 * alone; a paged object's made with ERX_MEM_CODE, through erx_vm_map once sealed.
	 */
	bool			code;
	bool			sealed;	/* a paged object's: no supply or copy writes it again */
} erx_fiasco_vm_traits_t;

/*
 * erx_vm_map of an object with prot: a device's memory to run, a slice other than
 * read-only, and a paged object written, or run without ERX_MEM_CODE, ERX_ERIGHTS; an
 * unsealed paged object ERX_EBUSY, since its supplier may still write it.
 */
int	erx_fiasco_vm_map_rule(erx_fiasco_vm_traits_t object, uint32_t prot) ERX_WARN_UNUSED_RESULT;
/* The loader's map of an image entry's segment: only a code slice, read or read-execute. */
int	erx_fiasco_vm_image_map_rule(erx_fiasco_vm_traits_t object, uint32_t prot) ERX_WARN_UNUSED_RESULT;
/*
 * erx_mem_copy from src into dst: a device's registers either side ERX_ETYPE; a slice
 * or a paged object as dst ERX_ERIGHTS, since a supply is a paged object's one writer.
 */
int	erx_fiasco_vm_copy_rule(erx_fiasco_vm_traits_t dst, erx_fiasco_vm_traits_t src) ERX_WARN_UNUSED_RESULT;
/*
 * What erx_mem_seal does to an object: status ERX_ETYPE for one that is not paged; for
 * a code object sealed for the first time, coherent, so that its pages are made
 * coherent for instruction fetch before the seal lets any map run them
 * (docs/design-arch-aarch64.md).
 */
typedef struct erx_fiasco_vm_seal {
	int	status;
	bool	coherent;
} erx_fiasco_vm_seal_t;

erx_fiasco_vm_seal_t	erx_fiasco_vm_seal_rule(erx_fiasco_vm_traits_t object) ERX_WARN_UNUSED_RESULT;
/* erx_mem_supply: a dst that is not paged, or device registers as src, ERX_ETYPE; a sealed dst ERX_ERIGHTS. */
int	erx_fiasco_vm_supply_rule(erx_fiasco_vm_traits_t dst, erx_fiasco_vm_traits_t src) ERX_WARN_UNUSED_RESULT;
/*
 * erx_mem_create_paged's arguments: a flag other than ERX_MEM_CODE (ERX_MEM_JIT, the
 * one writable code, included), or a size of 0 or off a page, ERX_EINVAL; ERX_MEM_CODE
 * from a task other than the root ERX_ERIGHTS, since the code right is the system
 * domain's.
 */
int	erx_fiasco_vm_paged_rule(uint64_t flags, uint64_t size, bool root) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_VM_RULES_H */
