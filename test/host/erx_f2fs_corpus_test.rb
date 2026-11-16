# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# F2FS's fixed corpora (docs/design-f2fs.md, "Corpora"): erx_f2fs_corpus decodes each image
# the fetch step provides and checks it against its pin, and erx_f2fs_codec reads its
# superblock and checkpoint pack; then the reader against damaged and hostile files. The
# EUnit cases run on stock's emulator (ERX_ERL and ERX_ERLC). A corpus the fetch step has
# not provided fails the test, naming its source.
class ErxF2fsCorpusTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_f2fs_corpus.erl test/erlang/erx_f2fs_corpus_tests.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')

  def test_eunit_cases_pass
    missing = JSON.parse(File.read(File.join(ROOT, 'deps.lock'))).fetch('sources')
                  .map { |source| source.fetch('id') }.grep(/\Af2fs-(?:syzkaller-|fuchsia\z)/)
                  .reject { |id| File.file?(File.join(CORPUS, id, '.source.json')) }
    assert_empty missing, 'corpora not fetched; run `ruby tools/erx fetch --source ID` for each'
    Dir.mktmpdir('erx-f2fs-corpus-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS)
      output, status =
        Open3.capture2e({ 'ERX_F2FS_CORPUS' => CORPUS }, 'gtimeout', '-k', '10', '900', ENV.fetch('ERX_ERL'),
                        '-noshell', '-pa', work, '-eval',
                        'halt(case eunit:test(erx_f2fs_corpus_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                        chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
