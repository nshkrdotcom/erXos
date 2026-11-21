# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../pcie_domain'
require_relative '../qemu_gate'

# The PCIe domain on QEMU virt under HVF (tools/lib/erx/pcie_domain.rb): the suite's own
# manifest (PcieDomain.manifest) boots with qemu-xhci attached at slot 2; the PCIe domain
# walks the ECAM bridge and reports, and the device service answers. Its cases are cells
# of the boot: walk, the catalogue against QMP's query-pci once the test holder has opened
# its function, and hold, the holder started only after the report's answer. Its boot
# carries a QMP socket, which no remote host serves, so it does not declare offload.
# check_qemu builds the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::PcieDomain.cells(Erx::QemuGate.suite_cells(cpus)),
  run: lambda do |context|
    run = Erx::PcieDomain::Run.new(root: context.root)
    ran = run.call(cpus: cpus, jobs: context.jobs, build: false, placement: context.placement)
    Erx::QemuGate.result(ran, notes: run.notes)
  end
)
