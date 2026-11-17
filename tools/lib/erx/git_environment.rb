# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The environment of a git child that must act on the repository it names and on
  # nothing else: every GIT_ variable of the caller's environment is unset.
  module GitEnvironment
    module_function

    def isolated = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
  end
end
