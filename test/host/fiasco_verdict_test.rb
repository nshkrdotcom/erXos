# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'
require_relative '../fixtures/pack_fixture'

# erx-gate: sanitizers

# The root's file verdicts on the host (docs/design-fiasco.md, "The call table",
# erx_image_map): an image entry's file is hashed once, by the first check, in the
# calling thread, and every later map of it reads the verdict, so the service thread,
# which only reads verdicts, never hashes a runtime image; a refused file stays refused
# (docs/design-kernel.md, "Verdicts"). Each seed below breaks one
# rule and the driver must name it. liberx/backend/fiasco/verdict.c is the core.
class FiascoVerdictTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/fiasco/verdict.c'
  DRIVER = 'test/fixtures/fiasco_verdict_driver.c'
  SOURCES = %w[kernel/core/pack.c liberx/image_plan.c kernel/crypto/blake3/blake3.c
               kernel/crypto/blake3/blake3_portable.c tools/host/input.c].freeze

  # name => [original, replacement, the driver's diagnostic].
  MUTANTS = {
    'a verdict that is not kept' => ["\t\tatomic_store_explicit(&verdicts->entry[index], (uint8_t)verdict, memory_order_release);\n", '',
                                     'a checked file was hashed twice'],
    'a refusal kept as good' => ['? VERDICT_GOOD : VERDICT_REFUSED', '? VERDICT_GOOD : VERDICT_GOOD',
                                 'a damaged file is not refused as damaged'],
    'a refusal checked again' => ['if (verdict == VERDICT_UNCHECKED) {', 'if (verdict != VERDICT_GOOD) {',
                                  'a refused file was hashed again']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-verdict-')
    @archive = File.join(@directory, 'archive.bin')
    File.binwrite(@archive, PackFixture.valid)
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'kernel/crypto'), '-I', ROOT,
                                  core, *SOURCES.map { |source| File.join(ROOT, source) },
                                  Erx::Generated.path('liberx/generated/abi_reader.c', root: ROOT),
                                  File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def test_each_file_is_hashed_once_and_a_damaged_one_never_reads_good
    log, status = Open3.capture2e(build(File.join(ROOT, CORE), name: 'verdict'), @archive, stdin_data: '')
    assert status.success?, log
    assert_equal "verdict: ok\n", log
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_mutant_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, CORE))
      assert_includes source, original
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, source.sub(original) { replacement })
      log, status = Open3.capture2e(build(seeded, name: "#{name} driver", flags: []), @archive, stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
