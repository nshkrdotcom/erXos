# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
load File.expand_path('../../tools/erx', __dir__)
require_relative '../../tools/lib/erx/production_image'

# The pure half of `tools/erx pack`: its options (Erx::CLI.pack_options). An image's
# packages lie in its medium's system partition, so an --app packs the medium as
# --medium does, and the header probe card takes neither. The medium's kind is stated,
# never inferred: --medium and --app pack a development medium, --published the one the
# website offers.
class ErxPackOptionsTest < Minitest::Test
  KIND = Erx::ProductionImage::MediumKind

  def test_an_app_implies_the_medium
    options = Erx::CLI.pack_options(['--app', 'examples/dashboard'])
    assert_equal KIND.development, options.medium
    assert_equal [File.expand_path('examples/dashboard')], options.sources
  end

  def test_without_an_app_the_medium_is_asked_for
    assert_nil Erx::CLI.pack_options(['--enable', 'clock']).medium
    assert_nil Erx::CLI.pack_options([]).medium
    assert_equal KIND.development, Erx::CLI.pack_options(['--medium']).medium
  end

  # Only --published packs the published medium, and it takes no app, signer or --local
  # of its builder's.
  def test_the_published_medium_is_stated
    assert_equal KIND.published, Erx::CLI.pack_options(['--published']).medium
    assert_equal KIND.published, Erx::CLI.pack_options(['--medium', '--published']).medium
    [%w[--app examples/dashboard], %w[--enable clock], %w[--signer key.pub], %w[--local]].each do |builders|
      error = assert_raises(Erx::Error) { Erx::CLI.pack_options(['--published', *builders]) }
      assert_equal 'pack: --published packs the medium the website offers, which takes no app, signer or --local',
                   error.message
    end
    error = assert_raises(Erx::Error) { Erx::CLI.pack_options(['--probe', 'header', '--published']) }
    assert_equal 'pack: --probe packs a card of its own and takes no --medium or --published', error.message
  end

  def test_the_probe_takes_no_app
    error = assert_raises(Erx::Error) { Erx::CLI.pack_options(['--probe', 'header', '--app', 'examples/dashboard']) }
    assert_equal 'pack: --probe packs a card of its own and takes no app', error.message
  end
end
