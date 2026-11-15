# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The errno table of the ABI file (abi/errno.txt) against the errno header
# erXos's musl builds with, musl/arch/generic/bits/errno.h
# (docs/design-programs.md, "The POSIX-lite personality"), and the
# generator's refusal of a malformed table.
class AbiErrnoTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MUSL_HEADER = File.join(ROOT, 'musl/arch/generic/bits/errno.h')
  ERRNO_DEFINE = /^#define\s+(E[A-Z0-9]+)\s+(\d+|E[A-Z0-9]+)\s*$/

  def test_errno_names_and_numbers_match_musl
    assert_equal musl, table(ROOT)
  end

  # Seeded fault: a table that swaps two numbers is well formed, so only the
  # comparison with musl's header refuses it.
  def test_comparison_catches_a_wrong_number
    swap = ->(text) { text.sub(/^errno eisdir 21$/, 'errno eisdir 22').sub(/^errno einval 22$/, 'errno einval 21') }
    seeded = seeded_root(swap) { |root| table(root) }
    assert_equal [22, 21], seeded.values_at('EISDIR', 'EINVAL')
    refute_equal musl, seeded
  end

  # Seeded faults: the generator refuses a repeated number, a repeated name or
  # alias, a name outside the closed form, a number out of range and a
  # malformed line.
  def test_generator_refuses_a_malformed_table
    {
      ->(text) { text + "errno eother 22\n" } => /duplicate errno number 22/,
      ->(text) { text + "errno einval 4000\n" } => /duplicate errno name einval/,
      ->(text) { text.sub(/^errno enotsup 95 alias eopnotsupp$/, 'errno enotsup 95 alias eagain') } =>
        /duplicate errno name eagain/,
      ->(text) { text.sub(/^errno edeadlk 35 alias edeadlock$/, 'errno edeadlk 35 alias ewouldblock') } =>
        /errno.txt:\d+: .*duplicate errno name ewouldblock/,
      ->(text) { text + "errno EBIG 200\n" } => /invalid errno name "EBIG"/,
      ->(text) { text + "errno ebig 4096\n" } => /errno number must be 1 to 4095/,
      ->(text) { text + "errno ebig 200 as ehuge\n" } => /expected errno NAME NUMBER \[alias NAME\]/
    }.each do |seed, message|
      error = assert_raises(Erx::ABI::SchemaError) { seeded_root(seed) { |root| table(root) } }
      assert_match message, error.message
    end
  end

  private

  # musl's errno names, each alias resolved to its number.
  def musl
    text = File.read(MUSL_HEADER)
    defines = text.scan(ERRNO_DEFINE).to_h
    assert_equal text.scan(/^#define\s+E/).size, defines.size, 'a define of the header escaped the comparison'
    defines.transform_values { |value| value.start_with?('E') ? Integer(defines.fetch(value)) : Integer(value) }
           .sort.to_h
  end

  # The table's names and aliases in upper case, with their numbers.
  def table(root)
    errnos = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64')).errnos
    numbers = errnos.errnos.to_h { |entry| [entry.name, entry.number] }
    numbers.merge(errnos.aliases.transform_values { |name| numbers.fetch(name) })
           .transform_keys(&:upcase).sort.to_h
  end

  # A copy of abi/ whose errno.txt the seed rewrote, handed to the block.
  def seeded_root(seed)
    Dir.mktmpdir('erx-abi-errno-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/errno.txt')
      text = File.read(path)
      refute_equal text, seed.call(text)
      File.write(path, seed.call(text))
      yield root
    end
  end
end
