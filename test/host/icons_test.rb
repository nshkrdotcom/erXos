# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/icons'

# The icon set's reader (Erx::Icons, docs/design-desktop-programs.md,
# "Icons"): every icon abi/formats/ui.txt's ui_icon names has paths in
# display/icons/icons.txt, in the enumeration's order, and a seeded missing
# icon, an icon outside the enumeration and a point that would take the
# stroke out of the square are refused. A layer reaches erx-raster in 26.6
# pixels with y upward.
class IconsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PATH = 'display/icons/icons.txt'
  TEXT = File.read(File.join(ROOT, PATH)).freeze
  NAMES = Erx::Icons.names(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT))).freeze

  def test_every_icon_ui_txt_names_has_paths
    set = Erx::Icons.read(root: ROOT, path: PATH)
    assert_equal NAMES, set.icons.map(&:name)
    assert(set.icons.all? { |icon| icon.base.any? })
    assert_equal [24, Rational(3, 2)], [set.grid, set.stroke]
  end

  def test_seeded_missing_icon_is_refused
    seeded = TEXT.sub(/^  icon folder\n(?:    .*\n)+/, '')
    refute_equal TEXT, seeded
    error = assert_raises(Erx::ABI::SchemaError) { parse(seeded) }
    assert_equal "#{PATH}: no paths for icon folder of ui_icon", error.message
  end

  def test_icon_outside_the_enumeration_is_refused
    error = assert_raises(Erx::ABI::SchemaError) { parse("#{TEXT}  icon kettle\n    base M 3 3 L 9 9\n") }
    assert_equal "#{PATH}: icon kettle is not in ui_icon", error.message
  end

  # Half the 1.5-unit stroke is 0.75: a point at 0.7 would take it outside.
  def test_point_beyond_half_a_stroke_from_the_edge_is_refused
    seeded = TEXT.sub('base M 3.75 12.75 L 20.25 12.75', 'base M 0.7 12.75 L 20.25 12.75')
    refute_equal TEXT, seeded
    error = assert_raises(Erx::ABI::SchemaError) { parse(seeded) }
    assert_match(/0\.7 lies outside the grid less half a stroke\z/, error.message)
  end

  # A cubic's control point may leave the grid less half a stroke only if
  # the curve could; refused like any other point.
  def test_control_point_beyond_half_a_stroke_is_refused
    seeded = TEXT.sub('C 1.68 16.68 1.68 13.32 3.75 11.25', 'C 0.5 16.68 1.68 13.32 3.75 11.25')
    refute_equal TEXT, seeded
    error = assert_raises(Erx::ABI::SchemaError) { parse(seeded) }
    assert_match(/0\.5 lies outside the grid less half a stroke\z/, error.message)
  end

  # forward's shaft at 16 pixels: 3.75 units is 2.5 pixels, 160 in 26.6;
  # 12.75 units down is 7.5 pixels up; the 1.5-unit stroke is one pixel.
  def test_layer_in_26_6_pixels_with_y_upward
    set = parse(TEXT)
    forward = set.icons.find { |icon| icon.name == 'forward' }
    assert_equal 'M 160 480 L 864 480', Erx::Icons.raster_path(set, forward.base.first(1), size: 16)
    assert_equal 64, Erx::Icons.raster_width(set, size: 16)
    assert_equal 128, Erx::Icons.raster_width(set, size: 32)
  end

  private

  def parse(text) = Erx::Icons.parse(text, path: PATH, names: NAMES)
end
