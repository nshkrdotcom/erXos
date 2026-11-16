# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/build_kind'

# The one decision the pack, manifest and boot-partition steps ask of a build kind
# (Erx::BuildKind): only the development kind is a development build, and a kind
# abi/erx_abi.txt does not name is refused rather than taken for release, which
# would quietly drop the development flag, or for development, which would admit
# the development login key and restricted licenses.
class BuildKindTest < Minitest::Test
  BuildKind = Erx::BuildKind

  def test_the_kinds_are_the_abi_rows
    assert_equal %w[development release], BuildKind::ALL
    assert_equal '-local', BuildKind::LOCAL_SUFFIX
  end

  def test_only_development_is_a_development_build
    assert BuildKind.development?('development')
    refute BuildKind.development?('release')
  end

  def test_any_other_kind_is_refused
    ['debug', 'Development', 'development-local', '', :development, nil].each do |kind|
      error = assert_raises(Erx::Error, kind.inspect) { BuildKind.development?(kind) }
      assert_includes error.message, kind.inspect
    end
  end
end
