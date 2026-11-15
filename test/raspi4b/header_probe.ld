/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The header probe's layout (test/raspi4b/header_probe.c). The builder
 * defines header_probe_address, where the firmware loads kernel8.img,
 * and writes the image as a flat binary from there: the entry first, then
 * the code and its constants. The 16 KiB stack follows, outside the file.
 */
ENTRY(header_probe_entry)

SECTIONS
{
	. = header_probe_address;
	.text : {
		KEEP(*(.text.entry))
		*(.text .text.*)
	}
	.rodata : { *(.rodata .rodata.*) }
	.data : { *(.data .data.*) }
	.bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) }
	.stack (NOLOAD) : ALIGN(16) {
		. += 0x4000;
		header_probe_stack_top = .;
	}
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}

ASSERT(header_probe_entry == header_probe_address, "the probe's entry must open the image")
/* Nothing clears memory past the file, so the probe keeps no zeroed data. */
ASSERT(SIZEOF(.bss) == 0, "the probe must keep no zero-initialized data")
