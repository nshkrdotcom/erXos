# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# How each end of the machine ends it, on the host (docs/design-stopgap.md, "The end
# path"): the driver holds every cause to its end, and each seed below must make it
# name the end it broke. liberx/backend/fiasco/end_how.c is the core.
class FiascoEndTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/fiasco/end_how.c'
  DRIVER = 'test/fixtures/fiasco_end_driver.c'
  # Each seed moves one cause's case label to another cause's end: name => [the cause,
  # the cause whose end it joins, the driver's diagnostic]. The first two are the old
  # power-off on a missed pet and on a root fault.
  MUTANTS = {
    'a missed pet powers off' => ['PET', 'STOP', 'a missed pet ends off, not reset'],
    'a root fault powers off' => ['FAULT', 'STOP', 'a root fault ends off, not reset'],
    'a requested power-off resets' => ['ASKED_OFF', 'PET', 'a requested power-off ends reset, not off']
  }.freeze

  def self.label(cause) = "\tcase ERX_FIASCO_END_#{cause}:\n"

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-end-')
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, core, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def test_each_cause_ends_the_machine_as_the_design_says
    log, status = Open3.capture2e(build(File.join(ROOT, CORE), name: 'end'), stdin_data: '')
    assert status.success?, log
    assert_equal "end: 5 cases\n", log
  end

  MUTANTS.each do |name, (cause, joins, diagnostic)|
    define_method("test_mutant_#{name.tr(' -', '__')}") do
      moved, kept = [cause, joins].map { |of| FiascoEndTest.label(of) }
      source = File.read(File.join(ROOT, CORE))
      assert_includes source, moved
      assert_includes source, kept
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, source.sub(moved, '').sub(kept) { kept + moved })
      log, status = Open3.capture2e(build(seeded, name: "#{name} driver"), stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
