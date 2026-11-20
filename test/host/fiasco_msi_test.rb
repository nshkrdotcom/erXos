# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# Fiasco's MSI line allocator (docs/design-pcie.md, "Verification", "Host tests of the
# pure cores"): the lines from the range's first to its last, then ERX_ELIMIT, and a
# freed line taken again. The seed moves the range's end one line out, and the driver
# must name the check it broke.
class FiascoMsiTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = File.join(ROOT, 'liberx/backend/fiasco/msi_lines.c')
  DRIVER = File.join(ROOT, 'test/fixtures/fiasco_msi_driver.c')
  # name => [original, replacement, the diagnostic].
  SEEDS = {
    "the range's end off by one" => ['offset < range.count', 'offset <= range.count', "a line past the range's end was taken"]
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-msi-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:)
    output = File.join(@directory, name.tr(' ', '-').delete("'"))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@sanitizer_flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, DRIVER, '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def test_lines_from_first_to_last
    log, status = Open3.capture2e(build(CORE, name: 'lines'), stdin_data: '')
    assert status.success?, log
    assert_match(/\Amsi_lines: [1-9]/, log)
  end

  SEEDS.each do |name, (original, replacement, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_').delete("'")}") do
      source = File.read(CORE)
      assert_equal 1, source.scan(original).size, "the seed's text is not in the core once: #{original}"
      seeded = File.join(@directory, 'msi_lines.c')
      File.write(seeded, source.sub(original) { replacement })
      log, status = Open3.capture2e(build(seeded, name: name), stdin_data: '')
      refute status.success?, "the seed '#{name}' passed: #{log}"
      assert_includes log, diagnostic
    end
  end
end
