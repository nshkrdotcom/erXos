# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../fixtures/erlang_build'

# The termios table of the ABI file (abi/termios.txt) against FreeBSD 15.1's
# sys/sys/_termios.h at deps.lock's freebsd-termios pin, the model's refusal
# of a malformed table, and test/erlang/erx_abi_termios_tests.erl, the
# generated codec's cases, compiled with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies)
# (docs/design-live.md, "The tty").
class AbiTermiosTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEFINE = /^#define\s+([A-Z_][A-Z0-9_]*)\s+(0x[0-9a-fA-F]+|\d+)U?\b/
  CASES = %w[test/erlang/erx_abi_termios_tests.erl].freeze
  DEADLINE = '300'

  def test_names_and_numbers_match_freebsd
    assert_empty mismatches(table_of(ROOT))
    header = File.read(freebsd_header)
    %w[tcflag_t speed_t].each { |type| assert_match(/^typedef\s+unsigned int\s+#{type};/, header) }
  end

  # Seeded fault: a table that swaps ECHOE's and ECHOK's bits is well formed,
  # so only the comparison with FreeBSD refuses it.
  def test_comparison_catches_a_wrong_bit
    table = seeded_table do |text|
      text.sub('flag echoe 0x00000002', 'flag echoe 0x00000004').sub('flag echok 0x00000004', 'flag echok 0x00000002')
    end
    assert_equal %w[ECHOE ECHOK], mismatches(table).map(&:first)
  end

  # Seeded faults: each breaks one rule of the table, which the model refuses.
  def test_malformed_tables_are_refused
    {
      ->(text) { text.sub('flag tab3 0x00000004', 'flag tab3 0x00000003') } => /tab3 must be one bit/,
      ->(text) { text.sub('flag cstopb 0x00000400', 'flag cstopb 0x00000200') } => /termios cflag names a bit twice/,
      ->(text) { text.sub('size csize 0x00000300 5', 'size csize 0x00000500 5') } => /csize must be contiguous/,
      ->(text) { text.sub('char vstatus 18', 'char vstatus 20') } => /char index must be below 20/,
      ->(text) { text.sub('char vstatus 18', 'char vstatus 17') } => /duplicate termios char index 17/,
      ->(text) { text.sub('flag ixany 0x00000800', 'flag echo 0x00000800') } => /duplicate termios name echo/,
      ->(text) { text.sub('flag hupcl 0x00004000', 'flag cc 0x00004000') } => /cc is a key of the termios map/,
      ->(text) { text.sub('flag noflsh 0x80000000', 'flag noflsh 0x100000000') } => /outside 32 bits/,
      ->(text) { text.sub(/^termios oflag\n(  flag .*\n)+/, '') } => /has no oflag section/,
      ->(text) { "#{text}termios iflag\n  flag ignbrk 0x1\n" } => /duplicate termios iflag/
    }.each do |seed, message|
      error = assert_raises(Erx::ABI::SchemaError) { seeded_table(&seed) }
      assert_match message, error.message
    end
  end

  def test_the_codec_cases_pass
    Dir.mktmpdir('erx-abi-termios-') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval',
                                       'halt(case eunit:test(erx_abi_termios_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  # Each name of the table whose number differs from FreeBSD's, upper-cased
  # as the header spells it, with the table's number and FreeBSD's.
  def mismatches(table)
    defines = File.read(freebsd_header).scan(DEFINE).to_h { |name, value| [name, Integer(value)] }
    flags = table.words.flat_map(&:flags).map { |flag| [flag.name.upcase, flag.bit] }
    sizes = table.words.flat_map(&:sizes).flat_map do |size|
      [[size.name.upcase, size.mask],
       *(size.first..size.last).map { |value| ["CS#{value}", (value - size.first) << size.shift] }]
    end
    chars = table.chars.map { |char| [char.name.upcase, char.index] }
    counts = [['NCCS', table.count], ['_POSIX_VDISABLE', table.unnamed]]
    (flags + sizes + chars + counts).filter_map do |name, value|
      [name, value, defines[name]] unless defines[name] == value
    end
  end

  def freebsd_header
    Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-termios').last
  end

  # The table of a copy of abi/ whose termios.txt the block rewrites.
  def seeded_table
    Dir.mktmpdir('erx-abi-termios-seed-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/termios.txt')
      text = File.read(path)
      seeded = yield(text)
      refute_equal text, seeded
      File.write(path, seeded)
      table_of(root)
    end
  end

  def table_of(root) = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64')).termios
end
