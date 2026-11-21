# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The device NIF's sources below ERTS's glue, read from their one list,
  # otp/erts/emulator/nifs/erxos/erx_device.mk, which ERTS's build includes as it stands.
  module DeviceNif
    DIRECTORY = 'otp/erts/emulator/nifs/erxos'
    LIST = File.join(DIRECTORY, 'erx_device.mk')
    ASSIGNMENT = /^ERX_DEVICE_CORES\s*=(.*)$/
    NAME = /\A[a-z0-9_]+\z/

    module_function

    # The sources, relative to the tree at root, with the cache maintenance of arch
    # ('aarch64' on the target, 'host' for host builds).
    def sources(root:, arch:)
      layer = File.join(DIRECTORY, 'arch', arch, 'erx_dma_arch.c')
      raise Error, "erx_device has no DMA architecture layer #{arch}" unless File.file?(File.join(root, layer))

      [*core_sources(root: root), layer]
    end

    # The cores without an architecture layer, for a harness that brings its own.
    def core_sources(root:) = cores(root).map { |name| File.join(DIRECTORY, "#{name}.c") }

    # The list's one plain assignment, its continuation lines joined: names only, which make
    # and this reader both take as they stand.
    def cores(root)
      assignments = File.read(File.join(root, LIST)).gsub("\\\n", ' ').scan(ASSIGNMENT)
      raise Error, "#{LIST} assigns ERX_DEVICE_CORES #{assignments.size} times, not once" unless assignments.size == 1

      names = assignments.first.first.split
      raise Error, "#{LIST} lists no sources" if names.empty?

      odd = names.grep_v(NAME)
      raise Error, "#{LIST} lists #{odd.join(', ')}, not plain source names" unless odd.empty?

      names
    end
  end
end
