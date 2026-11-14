# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ssh_dev_tests.erl, the cases of SSH's first stage
# (docs/design-ssh.md, "Stages"), against erx_ssh_dev compiled with the session
# application and erXos's ssh, every module of otp/lib/ssh/src ahead of stock's on the
# code path, on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies): root
# logs in with the login key and runs an expression, another user name and another key
# are refused, and the host key is made once and kept. Each seeded fault must fail the
# cases: a key callback that admits every user name, and OTP's encoding of an Ed25519
# private key without its public half, which ssh_file cannot read back as a host key.
class ErxSshDevTest < Minitest::Test
  SSH = File.join(ErlangBuild::ROOT, 'otp/lib/ssh/src')
  APPLICATIONS = %w[erx erx_shell erx_session].freeze
  TESTS = %w[test/erlang/erx_ssh_dev_tests.erl].freeze
  Fault = Data.define(:name, :source, :from, :to)
  FAULTS = [
    Fault.new(name: 'a callback for every user name', source: 'erlang/apps/erx_session/src/erx_ssh_dev.erl',
              from: 'is_auth_key(Key, ?USER, Options) ->', to: 'is_auth_key(Key, _, Options) ->'),
    Fault.new(name: 'an Ed25519 private key without its public half', source: 'otp/lib/ssh/src/ssh_message.erl',
              from: '?STRING(<<Priv/binary, Pub/binary>>)>>;', to: '?STRING(Priv)>>;')
  ].freeze

  def test_the_daemon_admits_root_with_the_login_key_alone
    in_build do |work|
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = File.read(File.join(ErlangBuild::ROOT, fault.source))
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{fault.source}"
      faulty = text.sub(fault.from, fault.to)
      in_build(fault.source.start_with?('otp/') ? { ssh: faulty } : { session: { fault.source => faulty } }) do |work|
        output, status = eunit(work)
        refute status.success?, "#{fault.name} passed erx_ssh_dev_tests:\n#{output}"
      end
    end
  end

  private

  # A work directory with the session's modules and the tests, and erXos's ssh in its
  # own ssh directory; replaced.fetch(:ssh) is ssh_message's text in place of the tree's.
  def in_build(replaced = {})
    Dir.mktmpdir('erx-ssh-dev-test') do |work|
      ebin = File.join(work, 'ssh')
      Dir.mkdir(ebin)
      sources = Dir[File.join(SSH, '*.erl')].sort
      if replaced.key?(:ssh)
        File.write(File.join(work, 'ssh_message.erl'), replaced.fetch(:ssh))
        sources = sources.map { |source| File.basename(source) == 'ssh_message.erl' ? File.join(work, 'ssh_message.erl') : source }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', ebin, '-I', SSH, *sources, stdin_data: '')
      assert status.success?, output
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced.fetch(:session, {}))
      yield work
    end
  end

  # erl's -pa puts the last directory it is given first on the code path.
  def eunit(work)
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, File.join(work, 'ssh'),
                    '-eval', 'halt(case eunit:test(erx_ssh_dev_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                    chdir: work, stdin_data: '')
  end
end
