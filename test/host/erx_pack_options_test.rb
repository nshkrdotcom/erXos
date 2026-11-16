# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
load File.expand_path('../../tools/erx', __dir__)

# The pure half of `tools/erx pack`: its options (Erx::CLI.pack_options). An image's
# packages lie in its medium's system partition, so an --app packs the medium as
# --medium does, and the header probe card takes neither.
class ErxPackOptionsTest < Minitest::Test
  def test_an_app_implies_the_medium
    options = Erx::CLI.pack_options(['--app', 'examples/dashboard'])
    assert options.medium
    assert_equal [File.expand_path('examples/dashboard')], options.sources
  end

  def test_without_an_app_the_medium_is_asked_for
    refute Erx::CLI.pack_options(['--enable', 'clock']).medium
    assert Erx::CLI.pack_options(['--medium']).medium
  end

  def test_the_probe_takes_no_app
    error = assert_raises(Erx::Error) { Erx::CLI.pack_options(['--probe', 'header', '--app', 'examples/dashboard']) }
    assert_equal 'pack: --probe packs a card of its own and takes no app', error.message
  end
end
