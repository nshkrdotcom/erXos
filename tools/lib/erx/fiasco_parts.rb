# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'dependency_status'

module Erx
  # The imported parts of the Fiasco tree, fiasco/PART, each with the status
  # docs/design.md's dependency table gives it: Fiasco's own parts, and
  # drivers-frst, which is replaced with Fiasco, are release; libfdt, which the
  # kernel and the root task keep, is permanent.
  module FiascoParts
    RELEASE = DependencyStatus::RELEASE
    STATUSES = {
      'kernel' => RELEASE,
      'mk' => RELEASE,
      'l4re-core' => RELEASE,
      'bootstrap' => RELEASE,
      'libfdt' => DependencyStatus::PERMANENT,
      'drivers-frst' => RELEASE
    }.freeze
    NAMES = STATUSES.keys.freeze

    module_function

    # The status a file of part is registered under.
    def status(part) = STATUSES.fetch(part)
  end
end
