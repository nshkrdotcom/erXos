# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The decoder of root's authorized_keys (docs/design-ssh.md, "Verification"):
# test/erlang/erx_boot_keys_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_boot_keys as it is, and against each seeded
# fault below, where the named case must fail.
class ErxBootKeysTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx/src/erx_boot_keys.erl'
  APPLICATIONS = %w[erx erx_files erx_blk erx_storage].freeze
  TESTS = %w[test/erlang/erx_boot_keys_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_boot_keys; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: '# lines taken as keys',
              from: '<<"#", _/binary>> -> ignored;', to: '<<"#!", _/binary>> -> ignored;',
              caught_by: 'a_hash_line_is_ignored_test'),
    Fault.new(name: 'the 16-key bound checked with >=',
              from: 'length(Keys) < ?KEYS_MAX', to: 'length(Keys) < ?KEYS_MAX - 1',
              caught_by: 'sixteen_keys_are_taken_and_seventeen_refuse_the_file_test'),
    Fault.new(name: 'the line bound off by one',
              from: 'Length > ?LINE_MAX', to: 'Length >= ?LINE_MAX',
              caught_by: 'a_line_of_1024_bytes_is_taken_and_one_of_1025_is_skipped_test'),
    Fault.new(name: 'the 16 KiB bound dropped',
              from: 'byte_size(File) =< ?FILE_MAX orelse', to: 'byte_size(File) >= 0 orelse',
              caught_by: 'a_file_of_16_kib_is_read_and_one_byte_more_is_refused_test'),
    Fault.new(name: "the blob's layout unchecked",
              from: 'when Name =:= ?ERX_SSH_ED25519_NAME_BYTES', to: 'when is_binary(Name)',
              caught_by: 'a_key_that_is_not_an_ed25519_blob_does_not_decode_test'),
    Fault.new(name: 'ssh-ed25519 looked for in any field',
              from: "{_, _} ->\n                    {skipped, not_a_plain_key}",
              to: "{_, Rest} ->\n                    line(Rest, 0)",
              caught_by: 'a_line_of_options_another_type_or_a_certificate_authority_is_skipped_test'),
    Fault.new(name: 'the key length checked as at least 68',
              from: 'key(Chars) when byte_size(Chars) =:= ?KEY_CHARS ->', to: 'key(Chars) when byte_size(Chars) >= ?KEY_CHARS ->',
              caught_by: 'a_key_not_of_68_base64_characters_does_not_decode_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name.
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_boot_keys_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the decoder as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-boot-keys-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_boot_keys_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
