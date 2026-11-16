/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/vm_rules.h"

static bool	copy_refused(erx_fiasco_vm_traits_t);

/*
 * A device's memory is never code: registers fault, and a device could write a run. A
 * slice's pages are the archive's, which no task writes. A paged object is never
 * written through a mapping, runs only with ERX_MEM_CODE, and maps only once sealed,
 * so no mapping of it exists while a supply can still change it. A child is a writable
 * copy of an immutable object's range, which nothing runs: it maps read and write at most.
 */
int
erx_fiasco_vm_map_rule(erx_fiasco_vm_traits_t object, uint32_t prot)
{
	switch (object.kind) {
	case ERX_FIASCO_VM_PAGES:
	case ERX_FIASCO_VM_JIT:
		return (ERX_OK);
	case ERX_FIASCO_VM_CHILD:
		return ((prot & ~(uint32_t)ERX_PROT_RW) == 0 ? ERX_OK : ERX_ERIGHTS);
	case ERX_FIASCO_VM_PHYSICAL:
	case ERX_FIASCO_VM_CONTIGUOUS:
		return (prot == ERX_PROT_RX ? ERX_ERIGHTS : ERX_OK);
	case ERX_FIASCO_VM_SLICE:
		return (prot == ERX_PROT_R ? ERX_OK : ERX_ERIGHTS);
	case ERX_FIASCO_VM_PAGED:
		if (prot == ERX_PROT_RW || (prot == ERX_PROT_RX && !object.code))
			return (ERX_ERIGHTS);
		return (object.sealed ? ERX_OK : ERX_EBUSY);
	}
	return (ERX_ERIGHTS);
}

/* The archive's pages, which the root holds read and execute and no task writes. */
int
erx_fiasco_vm_image_map_rule(erx_fiasco_vm_traits_t object, uint32_t prot)
{
	if (object.kind != ERX_FIASCO_VM_SLICE || !object.code || (prot != ERX_PROT_R && prot != ERX_PROT_RX))
		return (ERX_ERIGHTS);
	return (ERX_OK);
}

int
erx_fiasco_vm_copy_rule(erx_fiasco_vm_traits_t dst, erx_fiasco_vm_traits_t src)
{
	if (copy_refused(dst) || copy_refused(src))
		return (ERX_ETYPE);
	/* A paged object has one writer, the supply, which alone reads the seal. */
	if (dst.kind == ERX_FIASCO_VM_SLICE || dst.kind == ERX_FIASCO_VM_PAGED)
		return (ERX_ERIGHTS);
	return (ERX_OK);
}

/*
 * A sealed object's pages were made coherent at its first seal, and nothing has written
 * them since. A plain object is the target's shared object, which its kernel seals and
 * this backend does not.
 */
erx_fiasco_vm_seal_t
erx_fiasco_vm_seal_rule(erx_fiasco_vm_traits_t object)
{
	if (object.kind == ERX_FIASCO_VM_PAGES)
		return ((erx_fiasco_vm_seal_t){ .status = ERX_ENOTSUP });
	if (object.kind != ERX_FIASCO_VM_PAGED)
		return ((erx_fiasco_vm_seal_t){ .status = ERX_ETYPE });
	return ((erx_fiasco_vm_seal_t){ .status = ERX_OK, .coherent = object.code && !object.sealed });
}

/*
 * Bytes no copy or supply moves: a device's registers fault or change under it, and a
 * JIT object's pages change as its task runs them.
 */
static bool
copy_refused(erx_fiasco_vm_traits_t object)
{
	return (object.kind == ERX_FIASCO_VM_PHYSICAL || object.kind == ERX_FIASCO_VM_JIT);
}

int
erx_fiasco_vm_supply_rule(erx_fiasco_vm_traits_t dst, erx_fiasco_vm_traits_t src)
{
	if (dst.kind != ERX_FIASCO_VM_PAGED || copy_refused(src))
		return (ERX_ETYPE);
	return (dst.sealed ? ERX_ERIGHTS : ERX_OK);
}

int
erx_fiasco_vm_paged_rule(uint64_t flags, uint64_t size, bool root)
{
	if ((flags & ~(uint64_t)ERX_MEM_CODE) != 0 || size == 0 || size % ERX_PAGE_SIZE != 0)
		return (ERX_EINVAL);
	return ((flags & ERX_MEM_CODE) != 0 && !root ? ERX_ERIGHTS : ERX_OK);
}

/*
 * Only an immutable object parents a child, so the child's copy is the parent's bytes as
 * they stay: a slice, whose pages are the archive's, or a paged object once sealed.
 */
int
erx_fiasco_vm_child_rule(erx_fiasco_vm_traits_t parent, uint64_t parent_size, uint64_t offset, uint64_t size)
{
	uint64_t end;

	if (size == 0 || size % ERX_PAGE_SIZE != 0 || offset % ERX_PAGE_SIZE != 0)
		return (ERX_EINVAL);
	if (parent.kind != ERX_FIASCO_VM_SLICE && !(parent.kind == ERX_FIASCO_VM_PAGED && parent.sealed))
		return (ERX_ETYPE);
	if (__builtin_add_overflow(offset, size, &end) || end > parent_size)
		return (ERX_ERANGE);
	return (ERX_OK);
}
