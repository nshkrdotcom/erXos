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

# The errno table of the ABI file (abi/errno.txt) against FreeBSD 15.1's
# sys/sys/errno.h at deps.lock's freebsd-errno pin, musl's <errno.h> and
# strerror read through the generated header (docs/design-programs.md, "The
# POSIX-lite personality"), strerror's texts against lib/libc/gen/errlst.c at
# the freebsd-errlst pin, and the generator's refusal of a malformed table.
class AbiErrnoTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ERRNO_DEFINE = /^#define\s+(E[A-Z0-9]+)\s+(\d+|E[A-Z0-9]+)\b/
  STRERROR = File.join(ROOT, 'musl/src/errno/__strerror.h')
  STRERROR_ENTRY = /^E\((E[A-Z0-9]+),\s*"([^"]*)"\)$/
  DEADLINE = '60'
  LIMIT = ['gtimeout', '-k', '10', DEADLINE].freeze

  def test_errno_names_and_numbers_match_freebsd
    assert_equal freebsd, table(ROOT)
  end

  # Seeded fault: a table that swaps two numbers is well formed, so only the
  # comparison with FreeBSD's header refuses it.
  def test_comparison_catches_a_wrong_number
    swap = ->(text) { text.sub(/^errno eisdir 21$/, 'errno eisdir 22').sub(/^errno einval 22$/, 'errno einval 21') }
    seeded = seeded_root(swap) { |root| table(root) }
    assert_equal [22, 21], seeded.values_at('EISDIR', 'EINVAL')
    refute_equal freebsd, seeded
  end

  # musl's <errno.h>, compiled through the include directories erXos's musl
  # builds programs with, defines exactly the table's names and aliases with
  # the table's numbers.
  def test_musl_errno_header_matches_the_table
    assert_equal table(ROOT), musl_errno_macros
  end

  # strerror's table (musl/src/errno/__strerror.h), indexed by errno, has one
  # message for each errno of the table, under its name, and names nothing
  # else: an unlisted name would not build, a missing one reads as "No error
  # information", and an alias or a repeat would take another errno's slot.
  def test_strerror_describes_every_errno
    described = strerror_texts(File.read(STRERROR)).keys
    names = schema_of(ROOT).errnos.errnos.map { |entry| entry.name.upcase }
    assert_equal names.sort, described.sort
  end

  # Each strerror text is FreeBSD's text for the errno's number in
  # lib/libc/gen/errlst.c, not musl's own wording.
  def test_strerror_texts_match_freebsd_errlst
    assert_empty text_mismatches(File.read(STRERROR))
  end

  # Seeded fault: a text worded as musl words it is well formed, so only the
  # comparison with errlst.c refuses it.
  def test_comparison_catches_a_wrong_text
    seeded = File.read(STRERROR).sub('"Illegal seek"', '"Invalid seek"')
    refute_equal File.read(STRERROR), seeded
    assert_equal ['ESPIPE'], text_mismatches(seeded).keys
  end

  # Seeded faults: the generator refuses a repeated number, a repeated name or
  # alias, a name outside the closed form, a number out of range and a
  # malformed line.
  def test_generator_refuses_a_malformed_table
    {
      ->(text) { text + "errno eother 22\n" } => /duplicate errno number 22/,
      ->(text) { text + "errno einval 4000\n" } => /duplicate errno name einval/,
      ->(text) { text.sub(/^errno enotsup 45 alias eopnotsupp$/, 'errno enotsup 45 alias eagain') } =>
        /duplicate errno name eagain/,
      ->(text) { text.sub(/^errno edeadlk 11$/, 'errno edeadlk 11 alias ewouldblock') } =>
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

  # FreeBSD's errno names, each alias resolved to its number, but ELAST, which
  # names the largest errno number rather than an error.
  def freebsd
    _, path = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-errno')
    resolved(File.read(path).scan(ERRNO_DEFINE).to_h).except('ELAST')
  end

  # musl's <errno.h> as erXos's musl compiles it, preprocessed with the
  # build's include directories: each E macro with its number.
  def musl_errno_macros
    Dir.mktmpdir('erx-musl-errno-') do |work|
      clang = ENV.fetch('ERX_CLANG', 'clang')
      source = File.join(work, 'errnos.c')
      File.write(source, "#include <errno.h>\n")
      includes = Erx::Musl.new(root: ROOT, runner: nil, compiler: clang).include_directories(directory: work)
                          .flat_map { |path| ['-isystem', path] }
      macros = execute(*LIMIT, clang, '--target=aarch64-none-elf', '-nostdinc', '-std=c17', *includes,
                       '-E', '-dM', source)
      resolved(macros.scan(ERRNO_DEFINE).to_h)
    end
  end

  # The errnos whose text in a strerror table differs from FreeBSD's text for
  # the number: name => [text, FreeBSD's text].
  def text_mismatches(strerror)
    numbers = table(ROOT)
    freebsd = freebsd_texts
    strerror_texts(strerror).to_h { |name, text| [name, [text, freebsd.fetch(numbers.fetch(name))]] }
                            .reject { |_, (text, expected)| text == expected }
  end

  # The name => text of each E(NAME, "text") entry of a strerror table, but
  # entry 0, the catch-all. A line that starts an entry and does not read as
  # one is refused, so no entry escapes the comparison.
  def strerror_texts(strerror)
    entries = strerror.lines.grep(/^E\(E/).map(&:chomp)
    entries.to_h { |line| line.match(STRERROR_ENTRY)&.captures or flunk("unreadable strerror entry: #{line}") }
  end

  # FreeBSD's error text by errno number: sys_errlist is an array, so a text's
  # number is its position once the comments are removed. A slot that holds
  # __uprefix, the prefix of an unknown error, has no text.
  def freebsd_texts
    _, path = Erx::Dependencies.new(root: ROOT, runner: nil).archive_for('freebsd-errlst')
    body = File.read(path)[/sys_errlist\[\] = \{(.*?)^\};/m, 1] or flunk('no sys_errlist in errlst.c')
    body.gsub(%r{/\*.*?\*/}m, '').scan(/"([^"]*)"|__uprefix/).flatten.each_with_index.to_h { |text, number| [number, text] }
  end

  # Names with their numbers, a value naming another macro replaced by its number.
  def resolved(defines)
    defines.transform_values { |value| Integer(defines.fetch(value, value)) }.sort.to_h
  end

  # The table's names and aliases in upper case, with their numbers.
  def table(root)
    errnos = schema_of(root).errnos
    numbers = errnos.errnos.to_h { |entry| [entry.name, entry.number] }
    numbers.merge(errnos.aliases.transform_values { |name| numbers.fetch(name) })
           .transform_keys(&:upcase).sort.to_h
  end

  def schema_of(root) = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root, architecture: 'aarch64'))

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

  def execute(*argv)
    output, status = Open3.capture2e(*argv, stdin_data: '')
    assert status.success?, "#{argv.first(5).join(' ')} failed:\n#{output}"
    output
  end
end
