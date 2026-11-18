# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The statuses docs/design.md's dependency table gives a dependency (CLAUDE.md,
  # Dependencies): what deps.lock, a toolchain profile and a build's provenance record
  # may register a dependency under. permanent stays; release is in a release's trusted base
  # until a later phase replaces it, as Fiasco is; stopgap is replaced by the roadmap;
  # example is a demo that is never part of the system.
  module DependencyStatus
    PERMANENT = 'permanent'
    RELEASE = 'release'
    STOPGAP = 'stopgap'
    EXAMPLE = 'example'
    ALL = [PERMANENT, RELEASE, STOPGAP, EXAMPLE].freeze
  end
end
