# frozen_string_literal: true

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

require_relative 'manifest_edit'

module Erx
  # The PCIe domain's manifest on QEMU virt before its rows join the development manifest
  # (docs/design-pcie.md, "The rows and the facets' limits", "Where the rows live"): the
  # development manifest without its web domain, which gives back the room the web domain
  # took (Manifest::Edit.without_domain), with config/manifest/qemu-virt-pcie.txt
  # appended, whose rows take no more than that room.
  module PcieDomain
    PART = 'config/manifest/qemu-virt-pcie.txt'
    LEFT_OUT = 'web'

    # The manifest's text for platform, a Platform of QEMU virt, from root's sources.
    def self.manifest_source(root, platform:)
      without_web = Manifest::Edit.without_domain(platform.manifest_source(root), LEFT_OUT,
                                                  units: platform.record.fetch('units'))
      without_web + File.binread(File.join(root, PART))
    end
  end
end
