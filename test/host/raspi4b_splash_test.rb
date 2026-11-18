# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/raspi4b_shell'
require_relative '../../tools/lib/erx/ppm'
require_relative '../../tools/lib/erx/splash_mark'

# The raspi4b suite's check that the screen shows the splash
# (Raspi4bShell.splash_shown?): a screen of the background with the mark
# drawn in the text colour passes; a screen of the background alone, one
# whose text-coloured pixels spread wider or taller than the mark, one with
# fewer of them than half the mark's fully covered pixels, and one of
# another size, fail.
class Raspi4bSplashTest < Minitest::Test
  SHELL = Erx::Raspi4bShell
  FB = SHELL::FB
  BACKGROUND = '0d0f2a'
  TEXT = 'ffffff'
  # A mark of 8 by 4 pixels, its top and bottom rows fully covered, the rows
  # between half: 16 pixels drawn in exactly the text colour.
  MARK = Erx::SplashMark::Mask.new(width: 8, height: 4, pixels: ("\xff".b * 8) + ("\x80".b * 16) + ("\xff".b * 8))

  # A screen of FB's size in the background, with each [x, y] of inked in
  # the text colour.
  def screen(inked, width: FB::WIDTH, height: FB::HEIGHT)
    pixels = [BACKGROUND * (width * height)].pack('H*')
    inked.each { |x, y| pixels[((y * width) + x) * 3, 3] = [TEXT].pack('H*') }
    Erx::Ppm::Image.new(width: width, height: height, pixels: pixels)
  end

  # The mark's fully covered pixels with its top left corner at [left, top].
  def mark_at(left, top) = [top, top + MARK.height - 1].product((left...left + MARK.width).to_a).map(&:reverse)

  def shown?(image) = SHELL.splash_shown?(image, background: BACKGROUND, text: TEXT, mark: MARK)

  def test_the_mark_on_the_background_is_the_splash
    assert shown?(screen(mark_at(300, 200)))
  end

  def test_the_background_alone_is_not_the_splash
    refute shown?(screen([]))
  end

  # Half the mark's 16 fully covered pixels is enough; one fewer is not.
  def test_too_few_text_pixels_are_not_the_splash
    assert shown?(screen(mark_at(300, 200).first(8)))
    refute shown?(screen(mark_at(300, 200).first(7)))
  end

  def test_text_spread_wider_than_the_mark_is_not_the_splash
    refute shown?(screen(mark_at(300, 200) + [[100, 200]]))
  end

  def test_text_spread_taller_than_the_mark_is_not_the_splash
    refute shown?(screen(mark_at(300, 200) + [[300, 300]]))
  end

  def test_a_screen_of_another_size_is_not_the_splash
    refute shown?(screen([], width: FB::WIDTH / 2))
  end
end
