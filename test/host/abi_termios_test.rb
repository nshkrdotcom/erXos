# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/musl'
require_relative '../fixtures/erlang_build'

# The termios table of the ABI file (abi/termios.txt) against FreeBSD 15.1's
# sys/sys/_termios.h at deps.lock's freebsd-termios pin, musl's <termios.h>
# with the bits/termios.h generated from the table against the same header,
# the model's refusal of a malformed table, and
# test/erlang/erx_abi_termios_tests.erl, the
# generated codec's cases, compiled with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies)
# (docs/design-live.md, "The tty").
class AbiTermiosTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEFINE = /^#define\s+([A-Z_][A-Z0-9_]*)\s+(0x[0-9a-fA-F]+|\d+)U?\b/
  CASES = %w[test/erlang/erx_abi_termios_tests.erl].freeze
  DEADLINE = '300'
  LIMIT = ['gtimeout', '-k', '10', '60'].freeze
  CLANG = ['--target=aarch64-none-elf', '-nostdinc', '-std=c17'].freeze
  # What FreeBSD's sys/termios.h sets before it includes _termios.h, so
  # every name of the header is visible.
  VISIBLE = %w[-D__BSD_VISIBLE=1 -D__XSI_VISIBLE=700 -D__POSIX_VISIBLE=200809].freeze

  def test_names_and_numbers_match_freebsd
    assert_empty mismatches(table_of(ROOT))
    assert_equal freebsd_defines.keys.grep(/\AB\d+\z/).sort, table_macros(table_of(ROOT)).keys.grep(/\AB\d+\z/).sort
    header = File.read(freebsd_header)
    %w[tcflag_t speed_t].each { |type| assert_match(/^typedef\s+unsigned int\s+#{type};/, header) }
  end

  # musl's <termios.h> and <unistd.h>, as erXos's musl compiles them with
  # the headers the generator writes from the table: every macro of the
  # table's names has FreeBSD's value, and struct termios and its types have
  # FreeBSD's layout.
  def test_musl_header_matches_freebsd
    header = musl_termios(ROOT)
    assert_empty header_mismatches(table_of(ROOT), header.fetch(:macros))
    assert_equal freebsd_layout, header.fetch(:layout)
  end

  # Seeded faults: Linux's ICANON (02), swapped with ECHOE's bit so the table
  # stays well formed, moves into the header and fails the comparison; and
  # Linux's NCCS (32) gives a struct termios of another size.
  def test_header_follows_the_table
    linux = seeded_header do |text|
      text.sub('flag echoe 0x00000002', 'flag echoe 0x00000100').sub('flag icanon 0x00000100', 'flag icanon 0x00000002')
    end
    assert_equal 2, linux.fetch(:macros).fetch('ICANON')
    assert_equal %w[ECHOE ICANON], linux.fetch(:mismatches).map(&:first)
    nccs = seeded_header { |text| text.sub('termios cc 20 0xff', 'termios cc 32 0xff') }
    assert_equal 32, nccs.fetch(:macros).fetch('NCCS')
    refute_equal freebsd_layout, nccs.fetch(:layout)
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
      ->(text) { "#{text}termios iflag\n  flag ignbrk 0x1\n" } => /duplicate termios iflag/,
      ->(text) { text.sub('rate 76800', 'rate 57600') } => /duplicate termios rate 57600/,
      ->(text) { text.sub(/^termios speed\n(  rate .*\n)+/, '') } => /has no speed section/,
      ->(text) { text.sub('size csize 0x00000300 5', 'size cwidth 0x00000300 5') } => /cwidth must end in size/
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

  # Each name of the table whose number differs from FreeBSD's, with the
  # table's number and FreeBSD's.
  def mismatches(table)
    table_macros(table).reject { |name, value| freebsd_defines[name] == value }
                        .map { |name, value| [name, value, freebsd_defines[name]] }
  end

  # Each macro of musl's headers that FreeBSD's header defines, whose value
  # differs from FreeBSD's, and each name of the table the headers lack:
  # [name, musl's value, FreeBSD's].
  def header_mismatches(table, macros)
    missing = table_macros(table).keys - macros.keys
    differ = (freebsd_defines.keys & macros.keys).reject { |name| macros[name] == freebsd_defines[name] }
    (missing + differ).sort.map { |name| [name, macros[name], freebsd_defines[name]] }
  end

  # The macros the table gives a C program, spelled as FreeBSD's header
  # spells them, with the table's numbers.
  def table_macros(table)
    flags = table.words.flat_map(&:flags).map { |flag| [flag.name.upcase, flag.bit] }
    sizes = table.words.flat_map(&:sizes).flat_map do |size|
      [[size.name.upcase, size.mask],
       *(size.first..size.last).map { |value| ["CS#{value}", (value - size.first) << size.shift] }]
    end
    chars = table.chars.map { |char| [char.name.upcase, char.index] }
    rates = table.rates.map { |rate| ["B#{rate}", rate] }
    (flags + sizes + chars + rates + [['NCCS', table.count], ['_POSIX_VDISABLE', table.unnamed]]).to_h
  end

  def freebsd_defines
    @freebsd_defines ||= File.read(freebsd_header).scan(DEFINE).to_h { |name, value| [name, Integer(value)] }
  end

  def freebsd_header
    Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-termios').last
  end

  # musl's <termios.h> and <unistd.h> with the headers MuslEmitter writes
  # from root's table, in place of the build's generated directory: the
  # macros of the table's names and the layout of struct termios.
  def musl_termios(root)
    Dir.mktmpdir('erx-musl-termios-') do |work|
      generated = File.join(work, 'gen')
      Erx::ABI::MuslEmitter.outputs(schema_of(root)).each do |name, text|
        path = File.join(generated, name.delete_prefix("#{Erx::ABI::MuslEmitter::INCLUDE}/"))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
      end
      includes = musl_includes(work, generated)
      source = File.join(work, 'termios.c')
      File.write(source, "#include <termios.h>\n#include <unistd.h>\n")
      defines = execute(*LIMIT, clang, *CLANG, *includes, '-E', '-dM', source).scan(DEFINE)
      { macros: defines.to_h { |name, value| [name, Integer(value)] },
        layout: layout(work, '#include <termios.h>', includes) }
    end
  end

  # The include directories erXos's musl gives a program, with generated in
  # place of the build's generated directory, and a bits/alltypes.h made as
  # musl's build makes it.
  def musl_includes(work, generated)
    alltypes = File.join(work, 'obj/include/bits/alltypes.h')
    FileUtils.mkdir_p(File.dirname(alltypes))
    File.write(alltypes, execute('sed', '-f', File.join(ROOT, 'musl/tools/mkalltypes.sed'),
                                 File.join(ROOT, 'musl/arch/aarch64/bits/alltypes.h.in'),
                                 File.join(ROOT, 'musl/include/alltypes.h.in')))
    build = File.join(ROOT, Erx::Generated::OUTPUT, Erx::ABI::MuslEmitter::INCLUDE)
    directories = Erx::Musl.new(root: ROOT, runner: nil, compiler: clang).include_directories(directory: work)
    assert_includes directories, build
    directories.map { |path| path == build ? generated : path }.flat_map { |path| ['-isystem', path] }
  end

  # struct termios's size, alignment and member offsets, c_cc's size, and
  # the size and signedness of its three types, as the compiler lays them
  # out for aarch64, read from the assembly of an array of them.
  def layout(work, prologue, flags)
    members = [*Erx::ABI::Termios::WORDS, 'cc', *Erx::ABI::Termios::SPEEDS]
    values = ['sizeof(struct termios)', '_Alignof(struct termios)',
              *members.map { |member| "__builtin_offsetof(struct termios, c_#{member})" },
              'sizeof(((struct termios *)0)->c_cc)',
              *%w[tcflag_t cc_t speed_t].flat_map { |type| ["sizeof(#{type})", "(#{type})-1 > 0"] }]
    source = File.join(work, 'layout.c')
    File.write(source, [prologue, 'const unsigned long erx_layout[] = {', *values.map { |value| "  #{value}," }, '};', ''].join("\n"))
    assembly = execute(*LIMIT, clang, *CLANG, *flags, '-S', '-o', '-', source)
    numbers = assembly.scan(/^\s*\.xword\s+(\d+)\b/).flatten.map { |number| Integer(number) }
    assert_equal values.size, numbers.size, assembly
    values.zip(numbers).to_h
  end

  def freebsd_layout
    Dir.mktmpdir('erx-freebsd-termios-') { |work| layout(work, %(#include "#{freebsd_header}"), VISIBLE) }
  end

  def clang = ENV.fetch('ERX_CLANG', 'clang')

  def execute(*argv)
    output, status = Open3.capture2e(*argv, stdin_data: '')
    assert status.success?, "#{argv.first(5).join(' ')} failed:\n#{output}"
    output
  end

  # musl_termios of a copy of abi/ whose termios.txt the block rewrites,
  # with its mismatches against FreeBSD.
  def seeded_header(&seed)
    seeded_root(seed) do |root|
      header = musl_termios(root)
      header.merge(mismatches: header_mismatches(table_of(root), header.fetch(:macros)))
    end
  end

  # The table of a copy of abi/ whose termios.txt the block rewrites.
  def seeded_table(&seed) = seeded_root(seed) { |root| table_of(root) }

  # A copy of abi/ whose termios.txt seed rewrote, handed to the block.
  def seeded_root(seed)
    Dir.mktmpdir('erx-abi-termios-seed-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/termios.txt')
      text = File.read(path)
      seeded = seed.call(text)
      refute_equal text, seeded
      File.write(path, seeded)
      yield root
    end
  end

  def table_of(root) = schema_of(root).termios

  def schema_of(root) = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64'))
end
