/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A task's program: fixed addresses in the range table's area, past the thread
 * table's pages, with its file header and ABI note in the code segment, as
 * elf_plan.c asks, and each segment on a page of its own. A program linked with
 * musl finds its TLS image through the headers, and its constructors in .init_array.
 * musl sizes each thread's TLS from the tls segment, so that holds .tdata and .tbss and
 * nothing else. A section this script does not name would take the segments of the one before
 * it, so .got has its place ahead of them, and a task's link refuses an unnamed section
 * (NativeRoot::TASK_LINK_FLAGS). ERTS keeps data it seldom writes in ERTS_LOW_WRITE
 * (ERTS_WRITE_UNLIKELY in sys.h), which is data like any other here. erx_image_end marks
 * the end of the last segment, where liberx/program/image.c finds the program's image ends.
 * The base, erx_base, is the loader's window's, and the image ends below the window's last
 * page, erx_exec_record_page (abi/protocols/prog.txt): every link gives both with --defsym
 * (NativeRoot::TASK_PLACE_FLAGS), from the generated ABI, so the loader erx_exec, linked here
 * as every task is, never reaches the exec record's page.
 */
ENTRY(_start)
PHDRS {
	text PT_LOAD FILEHDR PHDRS FLAGS(5);
	rodata PT_LOAD FLAGS(4);
	data PT_LOAD FLAGS(6);
	tls PT_TLS FLAGS(4);
	note PT_NOTE FLAGS(4);
}
SECTIONS {
	. = erx_base + SIZEOF_HEADERS;
	.note.erx.abi : { KEEP(*(.note.erx.abi)) } :text :note
	.text : { *(.text .text.*) } :text
	. = ALIGN(4096);
	.rodata : { *(.rodata .rodata.*) } :rodata
	. = ALIGN(4096);
	.init_array : { KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*) .init_array)) } :data
	.fini_array : { KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*) .fini_array)) } :data
	.got : { *(.got .got.*) } :data
	.tdata : { *(.tdata .tdata.*) } :data :tls
	.tbss : { *(.tbss .tbss.*) } :data :tls
	.data : { *(.data .data.*) *(ERTS_LOW_WRITE) } :data
	.bss : { *(.bss .bss.* COMMON) } :data
	erx_image_end = .;
	ASSERT(erx_image_end <= erx_exec_record_page, "the image reaches the exec record's page (abi/protocols/prog.txt)")
	.symtab 0 : { *(.symtab) }
	.strtab 0 : { *(.strtab) }
	.shstrtab 0 : { *(.shstrtab) }
	/DISCARD/ : { *(.comment) *(.eh_frame*) *(.note.GNU-stack) *(.note.gnu.*) }
}
