# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The root service's reply slots (liberx/backend/fiasco/reply_slots.c), on the host:
# which of Fiasco's explicit reply slots each receive fills, and which hold a fault
# until its task stops. A receive into a slot that still holds a caller is what makes
# Fiasco warn on the console, so the seed lets a fault park the receive slot itself.
class FiascoReplyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/fiasco/reply_slots.c'
  DRIVER = 'test/fixtures/fiasco_reply_driver.c'

  def setup = @directory = Dir.mktmpdir('erx-fiasco-reply-')
  def teardown = FileUtils.remove_entry(@directory)

  def run_driver(core)
    output = File.join(@directory, 'driver')
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                                  '-I', ROOT, core, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    Open3.capture2e(output, stdin_data: '')
  end

  def test_no_receive_fills_a_parked_slot
    log, status = run_driver(File.join(ROOT, CORE))
    assert status.success?, log
    assert_equal "ok\n", log
  end

  def test_seed_park_the_receive_slot
    source = File.read(File.join(ROOT, CORE))
    original = 'slot != slots->receive && '
    assert_includes source, original, 'the seed no longer applies'
    seeded = File.join(@directory, File.basename(CORE))
    File.write(seeded, source.sub(original, ''))
    log, status = run_driver(seeded)
    refute status.success?, log
    assert_includes log, 'keeps the receive in its slot'
  end
end
