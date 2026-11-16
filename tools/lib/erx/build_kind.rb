# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'generated_abi'

module Erx
  # The build kinds, development and release, as abi/erx_abi.txt's build_kind_* rows give
  # them, and the one decision every build step asks of a kind: whether it is a development
  # build, which may carry the development login key, test code and packages whose license
  # is not permissive. A kind is a String; any other String is refused here, so no step
  # ever takes an unknown kind for release or for development.
  module BuildKind
    CODEC = ABI::Generated::CODEC
    private_constant :CODEC
    DEVELOPMENT = CODEC.fixed_bytes('build_kind_development').freeze
    RELEASE = CODEC.fixed_bytes('build_kind_release').freeze
    ALL = [DEVELOPMENT, RELEASE].freeze
    # What a local test image's configuration adds to its build kind (BuildFacts.configuration).
    LOCAL_SUFFIX = CODEC.fixed_bytes('build_kind_local_suffix').freeze

    module_function

    # The kind, as ALL holds it; anything else raises.
    def fetch(kind)
      known = ALL.find { |candidate| candidate == kind }
      raise Error, "#{kind.inspect} is not a build kind: it is neither #{DEVELOPMENT} nor #{RELEASE}" unless known

      known
    end

    # Whether kind, which must be a build kind, is the development kind.
    def development?(kind) = fetch(kind) == DEVELOPMENT
  end
end
