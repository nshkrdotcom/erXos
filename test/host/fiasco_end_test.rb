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
  # Each seed moves one cause's case label to another cause's group in one of the two
  # switches: name => [the function, the cause, the cause whose group it joins, the
  # driver's diagnostic]. The first four are the old power-off on a missed pet, a root
  # fault, the root's stop and a refusal; the last drains the log off the service.
  MUTANTS = {
    'a missed pet powers off' => [:how, 'PET', 'ASKED_OFF', 'a missed pet ends off, not reset'],
    'a root fault powers off' => [:how, 'FAULT', 'ASKED_OFF', 'a root fault ends off, not reset'],
    'the root stop powers off' => [:how, 'STOP', 'ASKED_OFF', "the root's stop ends off, not reset"],
    'a refusal powers off' => [:how, 'REFUSED', 'ASKED_OFF', 'a refusal ends off, not reset'],
    'a requested power-off resets' => [:how, 'ASKED_OFF', 'PET', 'a requested power-off ends reset, not off'],
    'a refusal drains the log' => [:drains, 'REFUSED', 'FAULT', 'a refusal drains the debug log, but must not']
  }.freeze
  # Where each function's switch begins in the core.
  FUNCTIONS = { how: "erx_fiasco_end_how(erx_fiasco_end_cause_t cause)\n",
                drains: "erx_fiasco_end_drains_log(erx_fiasco_end_cause_t cause)\n" }.freeze

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
    assert_equal "end: 6 cases\n", log
  end

  # The core with the cause's label moved to the group of joins' label, inside function's
  # switch alone, since both switches name every cause.
  def self.seeded(source, function:, cause:, joins:)
    start = source.index(FUNCTIONS.fetch(function))
    finish = source.index("\n}\n", start)
    moved, kept = [cause, joins].map { |of| label(of) }
    body = source[start...finish]
    raise "#{function} has no #{moved.strip} or #{kept.strip}" unless body.include?(moved) && body.include?(kept)

    source[0...start] + body.sub(moved, '').sub(kept) { kept + moved } + source[finish..]
  end

  MUTANTS.each do |name, (function, cause, joins, diagnostic)|
    define_method("test_mutant_#{name.tr(' -', '__')}") do
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, FiascoEndTest.seeded(File.read(File.join(ROOT, CORE)), function: function, cause: cause, joins: joins))
      log, status = Open3.capture2e(build(seeded, name: "#{name} driver"), stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
