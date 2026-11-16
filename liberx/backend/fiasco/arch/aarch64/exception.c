/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What an exception Fiasco reports is, from its syndrome: Fiasco passes ESR_EL1 as
 * the exception record's err word, and its SError entry from user mode
 * (fiasco/kernel/src/kern/arm/thread-arm.cpp, arm_serror_user_entry) passes the
 * SError's own. The exception class is ESR_EL1.EC, bits 31:26, whose value
 * '101111' Arm's Registers.json (SHA-256 06d6f82f60cd3e4defe687f7a9d182acdafca3cf
 * 914b432c3fbe848295794e9e, the pin hw/sysreg/ORIGIN.md records) links to the
 * syndrome it names an_SError_interrupt. ESR_EL1 is not in hw/sysreg/aarch64.json: its
 * layout depends on EC, which the refresh refuses.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/exception.h"

#define EXCEPTION_CLASS_SHIFT	26u
#define EXCEPTION_CLASS_MASK	UINT64_C(0x3f)
#define EXCEPTION_CLASS_SERROR	UINT64_C(0x2f)

erx_fault_kind_t
erx_fiasco_exception_kind(uint64_t syndrome)
{
	const uint64_t class = (syndrome >> EXCEPTION_CLASS_SHIFT) & EXCEPTION_CLASS_MASK;

	return (class == EXCEPTION_CLASS_SERROR ? ERX_FAULT_ASYNC_ERROR : ERX_FAULT_UNDEFINED);
}
