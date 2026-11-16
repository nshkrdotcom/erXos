# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The login facet's decoder (docs/design-ssh.md, "Verification"):
# test/erlang/erx_ssh_wire_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_ssh_wire as it is, and against each seeded
# fault below, where the named case must fail.
class ErxSshWireTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_ssh_login/src/erx_ssh_wire.erl'
  APPLICATIONS = %w[erx erx_ssh_login].freeze
  TESTS = %w[test/erlang/erx_ssh_wire_tests.erl].freeze
  STRING = 'string(<<Length:32, Rest/binary>>) when Length =< byte_size(Rest) ->'

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_ssh_wire; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'the length check off by one',
              from: STRING, to: 'string(<<Length:32, Rest/binary>>) when Length < byte_size(Rest) ->',
              caught_by: 'an_input_of_exactly_five_strings_decodes_test'),
    Fault.new(name: 'the string taken before its length is checked',
              from: STRING, to: 'string(<<Length:32, Rest/binary>>) ->',
              caught_by: 'a_length_past_the_end_is_refused_test'),
    Fault.new(name: 'the 64 KiB bound dropped',
              from: 'byte_size(Input) =< ?ERX_SSH_EXCHANGE_MAX', to: 'byte_size(Input) >= 0',
              caught_by: 'an_input_of_64_kib_decodes_and_one_byte_more_is_refused_test'),
    Fault.new(name: "the server KEXINIT's message number unchecked",
              from: 'cookie(<<?ERX_SSH_MSG_KEXINIT, Cookie', to: 'cookie(<<_, Cookie',
              caught_by: 'a_server_kexinit_without_its_message_number_and_cookie_is_refused_test'),
    Fault.new(name: "the key blob's name unchecked",
              from: "Key:?ERX_SSH_ED25519_KEY_SIZE/binary>>)\n    when Name =:= ?ERX_SSH_ED25519_NAME_BYTES ->",
              to: "Key:?ERX_SSH_ED25519_KEY_SIZE/binary>>)\n    when is_binary(Name) ->",
              caught_by: 'a_key_blob_of_another_length_or_name_is_refused_test')
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
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_ssh_wire_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the decoder as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-ssh-wire-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_ssh_wire_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
