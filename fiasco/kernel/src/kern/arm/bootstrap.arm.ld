/* Modified by erXos: the raw bootstrap keeps the dynamic symbols, the link
 * checks its relocations are in the format its relocator applies, and
 * _start_link_addr gives _start its link address. */
PHDRS
{
  phdr PT_PHDR PHDRS;
  rw PT_LOAD PHDRS;
  dyn PT_DYNAMIC;
}

SECTIONS {
  . = kernel_load_addr + 0x1000;
  .bootstrap.dropped_info : {
    *(.bootstrap.info)
    end_of_bootstrap_info = ABSOLUTE(.);
  } :rw

  .bootstrap.text : ALIGN(0x10) {
    start_of_loader = ABSOLUTE(.);
    *(.init)
    *(.text .text.* .gnu.linkonce.t.*)
    *(.glue_7t) *(.glue_7)

    *(.rodata .rodata.* .gnu.linkonce.r.* .rodata1)

    . = ALIGN(0x40);
    *(.data .data.* .gnu.linkonce.d.*)
    *(.anno)

    *(.bss .bss.* COMMON .gnu.linkonce.b.*)

    PROVIDE (_alt_insns_begin = .);
    KEEP(*(SORT(.alt_insns)))
    PROVIDE (_alt_insns_end = .);
    ASSERT(_alt_insns_begin == _alt_insns_end,
           "No alternative instruction patching in bootstrap!");
  } :rw

  /* _start's link address as an absolute symbol, a link-time constant that
   * needs no relocation: the AArch64 _start subtracts it from its run-time
   * address to find the load offset before relocate() has run. */
  _start_link_addr = ABSOLUTE(_start);

  /* Add dynamic symbol information. It keeps readelf happy when dumping
   * bootstrap.fiasco.pre.o, and the raw bootstrap keeps it too. */
  .dynsym         : { *(.dynsym) }
  .dynstr         : { *(.dynstr) }

  .rel.dyn        :
    {
      *(.rel.init)
      *(.rel.text .rel.text.* .rel.gnu.linkonce.t.*)
      *(.rel.fini)
      *(.rel.rodata .rel.rodata.* .rel.gnu.linkonce.r.*)
      *(.rel.data.rel.ro .rel.data.rel.ro.* .rel.gnu.linkonce.d.rel.ro.*)
      *(.rel.data .rel.data.* .rel.gnu.linkonce.d.*)
      *(.rel.tdata .rel.tdata.* .rel.gnu.linkonce.td.*)
      *(.rel.tbss .rel.tbss.* .rel.gnu.linkonce.tb.*)
      *(.rel.ctors)
      *(.rel.dtors)
      *(.rel.got)
      *(.rel.bss .rel.bss.* .rel.gnu.linkonce.b.*)
      *(.rel.iplt)
    }
  .rela.dyn       :
    {
      *(.rela.init)
      *(.rela.text .rela.text.* .rela.gnu.linkonce.t.*)
      *(.rela.fini)
      *(.rela.rodata .rela.rodata.* .rela.gnu.linkonce.r.*)
      *(.rela.data.rel.ro .rela.data.rel.ro.* .rela.gnu.linkonce.d.rel.ro.*)
      *(.rela.data .rela.data.* .rela.gnu.linkonce.d.*)
      *(.rela.tdata .rela.tdata.* .rela.gnu.linkonce.td.*)
      *(.rela.tbss .rela.tbss.* .rela.gnu.linkonce.tb.*)
      *(.rela.ctors)
      *(.rela.dtors)
      *(.rela.got)
      *(.rela.bss .rela.bss.* .rela.gnu.linkonce.b.*)
      *(.rela.iplt)
    }

  /* The relocator (Elf::relocate in bootstrap.cpp) applies the one format of
   * dynamic relocation whose tag bootstrap_reloc_tag names, DT_RELA (7) or
   * DT_REL (17), and skips the other without a word: a bootstrap linked with
   * the other format runs with none of its pointers relocated. Tag 0 is a
   * bootstrap without an MMU, which runs at its link address. */
  ASSERT(bootstrap_reloc_tag == 7 ? SIZEOF(.rel.dyn) == 0 :
         bootstrap_reloc_tag == 17 ? SIZEOF(.rela.dyn) == 0 :
         bootstrap_reloc_tag == 0,
         "bootstrap: dynamic relocations in a format its relocator skips")

  .rel.plt        : { *(.rel.plt) }
  .rela.plt       : { *(.rela.plt) }
  .plt            : { *(.plt) }
  .iplt           : { *(.iplt) }
  .got            : { *(.got.plt) *(.igot.plt) *(.got) *(.igot) } :rw
  .dynamic        : { *(.dynamic) } :dyn :rw

  end_of_loader = ABSOLUTE(.);
}
