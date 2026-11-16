# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/app_package'

# Runs test/erlang/erx_erofs_tests.erl, the EUnit cases of the EROFS reader and its
# funnel, and of its open files, erx_erofs_file, against erx_erofs, erx_erofs_file and
# erx_verity compiled from source with warnings as errors
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the fixture
# images tools/erofs_fixtures.rb wrote with fsimg, and of the funnel's hash check over
# trees the packer's writer, Erx::AppPackage#verity_tree, makes (write_verity_cases). erx_bytes
# is the host stand-in (test/erlang/host_bytes). The fuzz target,
# tools/fuzz/erx_erofs.rb, seeds the reader's faults.
class ErxErofsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[otp/erts/preloaded/src/erx_verity.erl otp/erts/preloaded/src/erx_verity_tree.erl
               otp/erts/preloaded/src/erx_erofs.erl test/erlang/host_bytes/erx_bytes.erl
               otp/erts/preloaded/src/erx_erofs_file.erl otp/erts/preloaded/src/erx_file_remote.erl
               build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl test/erlang/erx_erofs_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDES = %w[build/gen/erlang/apps/erx/include otp/lib/kernel/include].flat_map { |dir| ['-I', File.join(ROOT, dir)] }.freeze
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')

  def test_reader_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def eunit
    Dir.mktmpdir('erx-erofs-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', *INCLUDES, '-o', work, *SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      write_verity_cases(work)
      Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES, 'ERX_VERITY_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_erofs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end

  # One case of the hash check: the image's salt and bytes, what lies before the image (as
  # a package's header does) and between it and its tree, and whether NAME.img holds the
  # image or only the tree.
  VerityCase = Data.define(:salt, :image, :before, :gap, :stores_image) do
    def initialize(salt:, image:, before: ''.b, gap: ''.b, stores_image: true) = super
  end

  # The hash check's cases, each written as NAME.img, and their layouts in verity.terms as
  # {NAME, Layout}. "levels" puts a block of 0xFF between image and tree; "offset", a
  # package's shape, a block of 0xEE before the image; "deep", 16700 blocks under a tree
  # of three levels, stores only its tree: the EUnit case's window makes each image block
  # from its number, as numbered_blocks does.
  def verity_cases
    { 'levels' => VerityCase.new(salt: "\x05".b * 7, image: numbered_blocks(200), gap: "\xff".b * 4096),
      'offset' => VerityCase.new(salt: "\x0b".b * 3, image: numbered_blocks(130), before: "\xee".b * 4096),
      'one' => VerityCase.new(salt: "\x09".b, image: "\x07".b * 4096),
      'erofs' => VerityCase.new(salt: "\x01".b * 32, image: File.binread(File.join(FIXTURES, 'compact.img'))),
      'deep' => VerityCase.new(salt: "\x03".b * 5, image: numbered_blocks(16_700), stores_image: false) }
  end

  def write_verity_cases(work)
    terms = verity_cases.map do |name, verity_case|
      verity_case => { salt:, image:, before:, gap:, stores_image: }
      tree = Erx::AppPackage.verity_tree(image, salt: salt)
      File.binwrite(File.join(work, "#{name}.img"), stores_image ? before + image + gap + tree.bytes : tree.bytes)
      layout = { image_offset: before.bytesize, image_length: image.bytesize,
                 tree_offset: before.bytesize + image.bytesize + gap.bytesize,
                 tree_length: tree.bytes.bytesize, salt: salt, root_hash: tree.root_hash }
      "{\"#{name}\", #{erlang_map(layout)}}.\n"
    end
    File.write(File.join(work, 'verity.terms'), terms.join)
  end

  # count blocks, block I its number as a 32-bit big-endian word, 1024 times.
  def numbered_blocks(count) = (0...count).map { [it].pack('N') * 1024 }.join.b

  def erlang_map(fields)
    pairs = fields.map { |key, value| "#{key} => #{value.is_a?(String) ? "<<#{value.bytes.join(',')}>>" : value}" }
    "\#{#{pairs.join(', ')}}"
  end
end
