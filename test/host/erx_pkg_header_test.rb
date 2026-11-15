# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/fuzz/package_seeds'

# Runs test/erlang/erx_pkg_header_tests.erl, the EUnit cases of the package decoder,
# erx_pkg_header, and of the hash tree's layout, erx_verity_tree, compiled from source with
# warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
# The cases' package files are written here through the ABI codec (Erx::PackageSeeds):
# two well-formed packages, each decoded whole, and one file for each of the decoder's
# checks, wrong in a way only that check catches, with the answer it must give.
class ErxPkgHeaderTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[erlang/apps/erx/src/erx_pkg_header.erl erlang/apps/erx/src/erx_verity_tree.erl
               build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl
               test/erlang/erx_pkg_header_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  Seeds = Erx::PackageSeeds
  # An Erlang term the cases file spells: a tuple, and a reader refusal, which the EUnit
  # case matches by the reader's reason alone.
  Tuple = Data.define(:items)
  Refused = Data.define(:reason)

  def test_decoder_cases_pass_under_eunit
    output, status = eunit(cases)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def block = Seeds.block

  def erlang(name = 'erlang', **options) = Seeds.sample(name, declaration: Seeds::ERLANG, image_blocks: 3, tree_blocks: 1, **options)

  def cases
    accepted = [[erlang, expected(Seeds::ERLANG, start: Tuple.new([:applications, %w[erx_dashboard erx_charts]]))],
                [Seeds.sample('native', declaration: Seeds::NATIVE, image_blocks: 3, tree_blocks: 1),
                 expected(Seeds::NATIVE, start: Tuple.new([:program, 'bin/doom', ['-iwad', '', '/app/share/freedoom1.wad']]))]]
    long_read = erlang('long_read', prefix_edit: ->(bytes) { bytes + ("\xff".b * block) })
    accepted + [[long_read, accepted.first.last]] + refusals + cuts
  end

  # One file for each check, the first that fails answering.
  def refusals
    too_large = Seeds.codec.constant('pkg_bytes_max') + 1
    [[erlang('too_large', length_edit: ->(_) { too_large }), error(Tuple.new([:too_large, too_large]))],
     [erlang('magic', header_edit: ->(bytes) { bytes.dup.tap { |copy| copy.setbyte(0, 0) } }), header(Refused.new(:value))],
     [erlang('version', edits: ->(values) { values.merge('version' => 2) }), header(Refused.new(:value))],
     [erlang('header_past_file', length_edit: ->(_) { Seeds.codec.layout_size('erx_pkg_header') + 1 }),
      header(Refused.new(:length))],
     [erlang('seal_not_at_end', edits: ->(values) { values.merge('header_length' => values['header_length'] + 1) },
                                header_edit: ->(bytes) { bytes + "\0".b }), header(Refused.new(:trailing))],
     [erlang('both_starts', edits: ->(values) { values.merge('program' => values['name']) }), header(Refused.new(:inactive))],
     [erlang('header_past_max', edits: ->(values) { values.merge('header_length' => Seeds.header_max + 1) },
                                length_edit: ->(_) { 2 * Seeds.header_max }), header(Refused.new(:length))],
     # A read past the header's boundary but short of the bytes the decoder reads.
     [Seeds.sample('short_read', declaration: Seeds::ERLANG, image_blocks: 1, tree_blocks: 1,
                                 prefix_edit: ->(bytes) { bytes.byteslice(0, 2 * block) }), header(:short)],
     [erlang('short', length_edit: ->(_) { block - 1 }), header(:short)],
     [erlang('padding', prefix_edit: ->(bytes) { bytes.dup.tap { |copy| copy.setbyte(block - 1, 1) } }), header(:padding)],
     [erlang('tree_one_more', tree_blocks: 2), header(Tuple.new([:tree, 2, 1]))],
     [Seeds.sample('tree_one_less', declaration: Seeds::ERLANG, image_blocks: 129, tree_blocks: 2),
      header(Tuple.new([:tree, 2, 3]))],
     [erlang('one_block_short', length_edit: ->(length) { length - block }), error(Tuple.new([:length, 4 * block, 5 * block]))],
     [erlang('one_byte_long', length_edit: ->(length) { length + 1 }), error(Tuple.new([:length, (5 * block) + 1, 5 * block]))],
     # The tree over 2^32 - 1 blocks: 33554432 + 262144 + 2048 + 16 + 1 blocks.
     [Seeds.sample('image_past_file', declaration: Seeds::ERLANG, image_blocks: 0xffffffff, tree_blocks: 33_818_641,
                                      length_edit: ->(_) { 5 * block }),
      error(Tuple.new([:length, 5 * block, block * (1 + 0xffffffff + 33_818_641)]))]]
  end

  # The header cut at each field of its fixed part: the reader finds too few bytes.
  def cuts
    Seeds.codec.schema.types.fetch('erx_pkg_header').fields.map do |field|
      [erlang("cut_#{field.name}", length_edit: ->(_) { field.offset }), header(Refused.new(:truncated))]
    end
  end

  def expected(declaration, start:)
    Tuple.new([:ok, { name: declaration.name, abi_version: Seeds.codec.abi_version, arch: declaration.arch,
                      version: declaration.version, memory: declaration.memory, needs: declaration.needs,
                      start: start, license: declaration.license, key: "\x11".b * 32, signature: "\x22".b * 64,
                      header_length: Seeds.header(declaration, image_blocks: 3, tree_blocks: 1).bytesize,
                      layout: { image_offset: block, image_length: 3 * block, tree_offset: 4 * block,
                                tree_length: block, salt: "\x5a".b * 32, root_hash: "\xa5".b * 32 } }])
  end

  def header(reason) = error(Tuple.new([:header, reason]))
  def error(reason) = Tuple.new([:error, reason])

  def term(value)
    case value
    in Tuple(items:) then "{#{items.map { |item| term(item) }.join(', ')}}"
    in Refused(reason:) then "{refused, #{reason}}"
    in Symbol then value.to_s
    in Integer then value.to_s
    in String then "<<#{value.bytes.join(',')}>>"
    in Array then "[#{value.map { |item| term(item) }.join(', ')}]"
    in Hash then "\#{#{value.map { |key, item| "#{key} => #{term(item)}" }.join(', ')}}"
    end
  end

  # Each case's file bytes in NAME.bin, and cases.term: {Name, Length, Expected} for each.
  def eunit(cases)
    Dir.mktmpdir('erx-pkg-header-test') do |work|
      lines = cases.map do |sample, answer|
        File.binwrite(File.join(work, "#{sample.name}.bin"), sample.prefix)
        "{\"#{sample.name}\", #{sample.length}, #{term(answer)}}.\n"
      end
      File.write(File.join(work, 'cases.term'), lines.join)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, *SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_PKG_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_pkg_header_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end
end
