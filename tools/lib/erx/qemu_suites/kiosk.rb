# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../kiosk'
require_relative '../qemu_gate'

# The offline kiosk as an image package on its release medium (tools/lib/erx/kiosk.rb):
# the production image carries examples/dashboard at apps/dashboard.app of its system
# partition, the harness plays the firmware and boots it with a display under HVF, and
# the dashboard's screen equals the host's drawing of it at the minute it logged; the
# altered cell's package, its root hash flipped, is refused at its mount. HVF at one CPU
# is its one boot. Its boots carry a display, which no remote host serves, so it does not
# declare offload. check_qemu builds the kernel before any suite runs, so this suite does
# not.
Erx::QemuGate.declare_suite(
  cells: %W[#{Erx::QemuGate.suite_cells([1]).first} #{Erx::QemuGate.suite_cells([1]).first}#{Erx::Kiosk::ALTERED}],
  run: lambda do |context|
    Erx::QemuGate.result(Erx::Kiosk::Run.new(root: context.root).call(jobs: context.jobs, build: false))
  end
)
