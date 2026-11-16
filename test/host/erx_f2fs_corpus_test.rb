# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/dependencies'

# F2FS's fixed corpora (docs/design-f2fs.md, "Corpora"): erx_f2fs_corpus decodes each image
# the fetch step provides and checks it against the decoded image's pin in deps.lock, and
# erx_f2fs_codec reads its superblock and a checkpoint pack; then the reader against damaged
# and hostile files. The EUnit cases run on stock's emulator (ERX_ERL and ERX_ERLC). A
# corpus the fetch step has not provided, or whose fetched record is not deps.lock's pin,
# fails the test, naming its source.
class ErxF2fsCorpusTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_f2fs_corpus.erl test/erlang/erx_f2fs_corpus_tests.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')

  def test_eunit_cases_pass
    dependencies = Erx::Dependencies.new(root: ROOT, runner: nil)
    unfetched = dependencies.sources
                            .select { |source| source.key?('decoded_sha256') && source.fetch('id').start_with?('f2fs-') }
                            .map { |source| source.fetch('id') }.reject { |id| dependencies.fetched?(id) }
    assert_empty unfetched, 'corpora not fetched, or fetched for another pin: remove build/third_party/ID ' \
                            'and run `ruby tools/erx fetch --source ID` for each'
    Dir.mktmpdir('erx-f2fs-corpus-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS)
      output, status =
        Open3.capture2e({ 'ERX_F2FS_CORPUS' => CORPUS, 'ERX_DEPS_LOCK' => LOCK }, 'gtimeout', '-k', '10', '900', ENV.fetch('ERX_ERL'),
                        '-noshell', '-pa', work, '-eval',
                        'halt(case eunit:test(erx_f2fs_corpus_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                        chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
