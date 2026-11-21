# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# The root's slot pool on the host: the driver test/fixtures/slot_pool_driver.c takes pairs
# until the pool is exhausted, frees and takes again, and refuses frees of what is not taken.
# Each mutant below seeds a bug the core could have (docs/design-fiasco.md, "Handles", its
# seeded faults), and the driver must name it. liberx/backend/core/slot_pool.c is the core
# under test.
class SlotPoolTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/core/slot_pool.c'
  DRIVER = 'test/fixtures/slot_pool_driver.c'

  # name => [original, replacement, the driver's diagnostic]; each edits one place in slot_pool.c.
  MUTANTS = {
    'a take that does not mark its pair' => ["\t\tpool->taken[word] |= pair_bit(pool, *pair);\n", '',
                                             'two takes answered the same pair'],
    'a scan that stops one pair short' => ["\t\tif (index >= pool->pairs)\n", "\t\tif (index + 1 >= pool->pairs)\n",
                                           'the exhausting run ended a pair early']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-slot-pool-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_the_pool_takes_lowest_first_and_frees
    assert_match(/^ok: [1-9][0-9]* checks$/, run_driver(build(File.join(ROOT, CORE), name: 'driver')))
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_the_driver_catches_#{name.tr(' ', '_')}") do
      assert_includes driver_failure(mutant(name, original, replacement)), diagnostic
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(core, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *@sanitizer_flags,
                 *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT, core,
                 File.join(ROOT, DRIVER), '-o', output],
                name: "compile-#{name.tr(' ', '-')}", deadline: 60)
    output
  end

  def run_driver(driver)
    File.read(@runner.run([driver], name: 'run-driver', deadline: 60).fetch('log'))
  end

  # What the driver said as it failed; a driver that passes fails the test.
  def driver_failure(driver)
    output = run_driver(driver)
    flunk("the driver missed this: #{output}")
  rescue Erx::CommandError => e
    File.read(e.result.fetch('log'))
  end

  def mutant(name, original, replacement)
    source = File.read(File.join(ROOT, CORE))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
    path = File.join(@directory, "#{name.tr(' ', '-')}.c")
    File.write(path, source.sub(original) { replacement })
    build(path, name: "mutant-#{name}")
  end
end
