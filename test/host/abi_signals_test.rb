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
require_relative '../fixtures/generated_tree'

# The signal table of the ABI file (abi/signals.txt) against FreeBSD 15.1's
# sys/sys/signal.h and lib/libc/gen/siglist.c at deps.lock's freebsd-signal
# and freebsd-siglist pins, the numbers read through the generated header
# (docs/design-programs.md, "Signal numbers"), and the generated C lookups
# run over every number around the table's range.
class AbiSignalsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The one alias erXos adds to FreeBSD's names: SIGPOLL, Linux's name of SIGIO.
  OWN_ALIASES = { 'POLL' => 23 }.freeze
  SIGNAL_DEFINE = /^#define\s+SIG([A-Z0-9]+)\s+(\d+|SIG[A-Z0-9]+)\b/
  GENERATED_DEFINE = /^#define ERX_SIG([A-Z0-9]+) INT32_C\((\d+)\)$/
  # One entry of siglist.c's arrays: [SIGHUP] =\t"Hangup",
  SIGLIST_ENTRY = /^\s*\[SIG([A-Z0-9]+)\]\s*=\s*"([^"]*)",$/
  DEADLINE = '60'
  LIMIT = ['gtimeout', '-k', '10', DEADLINE].freeze

  def test_signal_names_and_numbers_match_freebsd
    assert_equal freebsd, generated(ROOT)
  end

  # Each signal of a signal line a program may name has FreeBSD's sys_signame name and
  # sys_siglist description, and those are exactly the signals 1 to 31.
  def test_names_and_descriptions_match_freebsd_siglist
    assert_equal siglist, described(ROOT)
  end

  # Seeded fault: a description that differs from FreeBSD's by one character
  # is well formed, so only the comparison with siglist.c refuses it.
  def test_comparison_catches_a_wrong_description
    Dir.mktmpdir('erx-abi-signals-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/signals.txt')
      text = File.read(path)
      seeded = text.sub(/^(signal hup 1 terminate) "Hangup"$/, '\1 "Hang up"')
      refute_equal text, seeded
      File.write(path, seeded)
      table = described(root)
      assert_equal ['HUP', 'Hang up'], table.fetch(1)
      refute_equal siglist, table
    end
  end

  # Seeded faults: a signal a program may name without a description, a
  # reserved number with one, a name that comes in quotes, a blank
  # description, a signal on number 34, which the C library keeps, and a
  # reserved_signal line with a description, an extra number or a repeat each
  # fail generation.
  def test_malformed_signal_lines_fail_generation
    {
      ->(text) { text.sub(/^signal int 2 terminate "Interrupt"$/, 'signal int 2 terminate') } =>
        /signal int needs its description/,
      ->(text) { text.sub(/^signal librt 33 reserved$/, 'signal librt 33 reserved "Real-time"') } =>
        /reserved signal librt takes no description/,
      ->(text) { text.sub(/^signal quit 3 /, 'signal "quit" 3 ') } => /quoted token is not permitted here/,
      ->(text) { text.sub(/^(signal ill 4 terminate) "Illegal instruction"$/, '\1 " "') } =>
        /signal ill needs its description/,
      ->(text) { text + "signal syncall 34 terminate \"Sync call\"\n" } => /duplicate signal number 34/,
      ->(text) { text.sub(/^reserved_signal 34$/, 'reserved_signal 34 "Sync call"') } =>
        /quoted token is not permitted here/,
      ->(text) { text.sub(/^reserved_signal 34$/, 'reserved_signal 34 35') } => /expected reserved_signal NUMBER/,
      ->(text) { text.sub(/^reserved_signal 34$/, "reserved_signal 34\nreserved_signal 34") } =>
        /duplicate signal number 34/
    }.each do |seed, message|
      assert_seeded_failure('abi/signals.txt', seed, message)
    end
  end

  # Seeded fault: a table that swaps SIGINFO's and SIGUSR1's numbers is well
  # formed, so only the comparison with FreeBSD refuses it.
  def test_comparison_catches_a_wrong_number
    Dir.mktmpdir('erx-abi-signals-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/signals.txt')
      text = File.read(path)
      seeded = text.sub(/^signal info 29 /, 'signal info 30 ').sub(/^signal usr1 30 /, 'signal usr1 29 ')
      refute_equal text, seeded
      File.write(path, seeded)
      table = generated(root)
      assert_equal [30, 29], table.values_at('INFO', 'USR1')
      refute_equal freebsd, table
    end
  end

  # erx_sig_valid holds for 1 to 31 and 65 to 126 only; erx_sig_name and
  # erx_sig_action answer for every listed number, reserved ones included.
  def test_generated_c_lookups
    Dir.mktmpdir('erx-abi-signals-c-') do |work|
      header = File.join(work, 'erx/abi.h')
      FileUtils.mkdir_p(File.dirname(header))
      File.write(header, header_of(ROOT))
      source = File.join(work, 'lookups.c')
      File.write(source, <<~C)
        #include <stdio.h>
        #include <erx/abi.h>

        int
        main(void)
        {
        	for (int n = -1; n <= 200; n++) {
        		const char *name = erx_sig_name(n);
        		const char *description = erx_sig_description(n);

        		printf("%d %d %d %s %s\\n", n, erx_sig_valid(n), erx_sig_action(n), name ? name : "-",
        		    description ? description : "-");
        	}
        	return (0);
        }
      C
      binary = File.join(work, 'lookups')
      execute(*LIMIT, ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-I', work,
          '-o', binary, source)
      rows = execute(*LIMIT, binary).lines.map(&:split)
      valid = rows.select { |row| row[1] == '1' }.map { |row| Integer(row[0]) }
      assert_equal [*1..31, *65..126], valid
      named = rows.to_h { |row| [Integer(row[0]), row[3]] }
      assert_equal %w[HUP STOP INFO THR LIBRT RTMIN RTMIN+1 RTMIN+30 RTMAX-30 RTMAX -],
                   named.values_at(1, 17, 29, 32, 33, 65, 66, 95, 96, 126, 34)
      actions = rows.to_h { |row| [Integer(row[0]), Integer(row[2])] }
      expected = { 0 => 'NONE', 1 => 'TERMINATE', 16 => 'IGNORE', 17 => 'STOP', 19 => 'CONTINUE',
                   23 => 'IGNORE', 32 => 'RESERVED', 34 => 'RESERVED', 35 => 'NONE', 64 => 'NONE',
                   126 => 'TERMINATE', 127 => 'NONE' }
      assert_equal expected.transform_values { |action| action_value(action) }, actions.slice(*expected.keys)
      described = rows.to_h { |row| [Integer(row[0]), row.drop(4).join(' ')] }
      assert_equal(described(ROOT).transform_values(&:last), described.reject { |_n, text| text == '-' })
    end
  end

  # The fault table gives each fault kind of abi/kernel.txt but exit the
  # signal docs/design-programs.md's "A program's end" names, and
  # erx_fault_signal answers it by the kind's number, and 0 for any other.
  def test_fault_table_and_its_c_lookup
    Dir.mktmpdir('erx-abi-faults-c-') do |work|
      header = File.join(work, 'erx/abi.h')
      FileUtils.mkdir_p(File.dirname(header))
      File.write(header, header_of(ROOT))
      source = File.join(work, 'faults.c')
      File.write(source, <<~C)
        #include <stdio.h>
        #include <erx/abi.h>

        int
        main(void)
        {
        	printf("%lld", (long long)ERX_EXIT_SIGNAL);
        	for (uint32_t kind = 0; kind <= 10; kind++)
        		printf(" %d", erx_fault_signal(kind));
        	printf(" %d\\n", erx_fault_signal(UINT32_MAX));
        	return (0);
        }
      C
      binary = File.join(work, 'faults')
      execute(*LIMIT, ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-I', work,
          '-o', binary, source)
      assert_equal "256 0 11 10 4 10 5 12 10 9 0 0 0\n", execute(*LIMIT, binary)
    end
  end

  # Seeded fault: a fault kind without a row in the fault table fails
  # generation, and so do a row for exit, which is no fault, a second row
  # for a kind, a row naming a signal no program may name, and a signal
  # base that would read a halt status as a signal.
  def test_fault_table_must_be_total
    {
      ->(text) { text.sub(/^fault budget kill\n/, '') } => /fault kind budget has no signal/,
      ->(text) { text + "fault exit kill\n" } => /exit is no fault kind/,
      ->(text) { text + "fault memory bus\n" } => /duplicate fault kind memory/,
      ->(text) { text.sub(/^  value signal 256$/, '  value signal 128') } => /exit_kind signal must exceed 255/,
      ->(text) { text.sub(/^fault budget kill$/, 'fault budget thr') } => /fault budget names no signal/
    }.each do |seed, message|
      assert_seeded_failure('abi/erx_abi.txt', seed, message)
    end
  end

  # musl's <signal.h>, compiled through the include directories erXos's musl
  # builds programs with, defines each name and alias of the table with its
  # number, SIGRTMIN and SIGRTMAX as the realtime range's ends, _NSIG as the
  # set's 128 bits, and no signal the table does not list. The signals the C
  # library keeps are defined only for _BSD_SOURCE or _GNU_SOURCE.
  def test_musl_signal_header_matches_the_table
    table = schema_of(ROOT).signals
    numbers = table.signals.select(&:name).to_h { |signal| [signal.name.upcase, signal.number] }
    constants = numbers.select { |name, _number| name.match?(/\A[A-Z][A-Z0-9]*\z/) }
                       .merge(table.aliases.to_h { |alias_name, name| [alias_name.upcase, numbers.fetch(name.upcase)] })
                       .merge('_NSIG' => 128)
    kept = %w[THR LWP LIBRT]
    assert_equal constants.sort.to_h, musl_signal_macros('-D_BSD_SOURCE')
    assert_equal constants.sort.to_h, musl_signal_macros('-D_GNU_SOURCE')
    assert_equal constants.except(*kept).sort.to_h, musl_signal_macros('-D_POSIX_C_SOURCE=200809L')
  end

  # Seeded fault: two signals that share an alias fail generation.
  def test_shared_alias_fails_generation
    seed = ->(text) { text.sub(/^signal thr 32 reserved alias lwp$/, 'signal thr 32 reserved alias iot') }
    assert_seeded_failure('abi/signals.txt', seed, /duplicate signal name iot/)
  end

  private

  # Generation of a copy of abi/ whose file the seed rewrote fails with message.
  def assert_seeded_failure(file, seed, message)
    Dir.mktmpdir('erx-abi-faults-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, file)
      text = File.read(path)
      refute_equal text, seed.call(text)
      File.write(path, seed.call(text))
      error = assert_raises(Erx::ABI::SchemaError) { header_of(root) }
      assert_match message, error.message
    end
  end

  # musl's <signal.h> as a program compiled against erXos's musl with the
  # feature macro sees it: each SIG macro, without SIG, whose value is a
  # number or another SIG macro (resolved), and _NSIG. SIGSTKSZ is a size,
  # not a signal.
  def musl_signal_macros(feature)
    Dir.mktmpdir('erx-musl-signal-') do |work|
      clang = ENV.fetch('ERX_CLANG', 'clang')
      alltypes = File.join(work, 'obj/include/bits/alltypes.h')
      FileUtils.mkdir_p(File.dirname(alltypes))
      File.write(alltypes, execute('sed', '-f', File.join(ROOT, 'musl/tools/mkalltypes.sed'),
                                   File.join(ROOT, 'musl/arch/aarch64/bits/alltypes.h.in'),
                                   File.join(ROOT, 'musl/include/alltypes.h.in')))
      source = File.join(work, 'signals.c')
      File.write(source, "#include <signal.h>\n")
      includes = Erx::Musl.new(root: ROOT, runner: nil, compiler: clang).include_directories(directory: work)
                          .flat_map { |path| ['-isystem', path] }
      macros = execute(*LIMIT, clang, '--target=aarch64-none-elf', '-nostdinc', '-std=c17', feature,
                       *includes, '-E', '-dM', source)
      defines = macros.scan(/^#define (SIG[A-Z0-9]+|_NSIG) (\S+)$/).to_h.except('SIGSTKSZ')
      defines.to_h { |name, value| [name.delete_prefix('SIG'), Integer(defines.fetch(value, value))] }.sort.to_h
    end
  end

  def action_value(action)
    Integer(header_of(ROOT)[/^#define ERX_SIG_ACTION_#{action} INT32_C\((\d+)\)$/, 1])
  end

  # FreeBSD's signal names without SIG, aliases resolved to their numbers.
  def freebsd
    _, path = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-signal')
    defines = File.read(path).scan(SIGNAL_DEFINE).to_h
    defines.transform_values do |value|
      value.start_with?('SIG') ? Integer(defines.fetch(value.delete_prefix('SIG'))) : Integer(value)
    end.sort.to_h
  end

  # FreeBSD's sys_signame and sys_siglist by number, signal 0 left out:
  # each number with its name and its description.
  def siglist
    _, path = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-siglist')
    numbers = freebsd
    parts = File.read(path).split(/^const char \*const sys_siglist\[NSIG\] = \{$/)
    assert_equal 2, parts.size, 'siglist.c defines sys_signame, then sys_siglist'
    names, descriptions = parts.map { |part| part.scan(SIGLIST_ENTRY).to_h }
    assert_equal names.keys, descriptions.keys
    names.to_h { |name, text| [numbers.fetch(name), [text, descriptions.fetch(name)]] }.sort.to_h
  end

  # The described signals of the table beneath root by number: each with its
  # name without SIG in upper case and its description.
  def described(root)
    schema_of(root).signals.signals.select(&:description)
                   .to_h { |signal| [signal.number, [signal.name.upcase, signal.description]] }
  end

  # The table's names and aliases without SIG, as the generated header numbers them.
  def generated(root)
    header_of(root).scan(GENERATED_DEFINE).to_h { |name, number| [name, Integer(number)] }
          .reject { |name, number| OWN_ALIASES[name] == number }.sort.to_h
  end

  # The generated erx/abi.h of the ABI files beneath root, from the model and
  # the C emitter alone, so a seeded copy of abi/ needs no other input.
  def header_of(root) = Erx::ABI::CEmitter.header(schema_of(root))

  def schema_of(root) = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64'))

  def execute(*argv)
    output, status = Open3.capture2e(*argv, stdin_data: '')
    assert status.success?, "#{argv.first(5).join(' ')} failed:\n#{output}"
    output
  end
end
