# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# erx_sae, SAE's exchange in the join machine (docs/design-wifi.md, "SAE and protected
# management frames" and "Verification"): its EUnit cases on stock's emulator, Annex
# J.10's vectors and whole exchanges against test/erlang/erx_sae_peer.erl's holder and
# access point among them, then the same cases against an erx_sae with one seeded fault
# each, which must fail the case named for it.
class ErxSaeTest < Minitest::Test
  SAE = 'erlang/apps/erx_wifi/src/erx_sae.erl'
  TESTS = %w[test/erlang/erx_sae_tests.erl test/erlang/erx_sae_peer.erl].freeze
  ROOT = File.expand_path('../..', __dir__)

  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  def self.failed(name) = /#{name}[^\n]*\*failed\*/

  SEEDS = [
    Seed.new(fault: 'an element coordinate at or above the prime accepted',
             anchor: 'below(X, Prime) andalso below(Y, Prime)', replacement: 'true',
             failure: failed('invalid_element_dropped_before_the_holder')),
    Seed.new(fault: 'a reflected commit accepted',
             anchor: 'not reflects(Peer, Own) orelse', replacement: 'true orelse',
             failure: failed('reflected_commit')),
    Seed.new(fault: 'a reflection recognised only when scalar and element both match',
             anchor: 'Scalar =:= OwnScalar orelse Element =:= OwnElement',
             replacement: 'Scalar =:= OwnScalar andalso Element =:= OwnElement',
             failure: failed('reflected_commit')),
    Seed.new(fault: 'a scalar of 1 accepted',
             anchor: 'in_range(Scalar, 2, Order)', replacement: 'in_range(Scalar, 1, Order)',
             failure: failed('scalar_out_of_range')),
    Seed.new(fault: "the peer's send-confirm left out of the verifier",
             anchor: 'confirm(Kck, Sc, Peer, Own)', replacement: 'confirm(Kck, 1, Peer, Own)',
             failure: failed('confirm_send_confirm_is_verified')),
    Seed.new(fault: 'the send-confirm not counted on a resent confirm',
             anchor: 'Sc = min(Sent + 1, ?ERX_SAE_SEND_CONFIRM_MAX),', replacement: 'Sc = 1,',
             failure: failed('retry_limits')),
    Seed.new(fault: 'the anti-clogging token ignored',
             anchor: '(ext_element(?ERX_IEEE80211_EID_EXT_ANTI_CLOGGING_TOKEN, Token))/binary',
             replacement: '<<>>/binary',
             failure: failed('anti_clogging_token')),
    Seed.new(fault: 'a Rejected Groups list naming group 19 ignored',
             anchor: 'lists:member(?ERX_SAE_GROUP, Groups)', replacement: 'false',
             failure: failed('downgrade_list_naming_group_19_ends_the_exchange')),
    Seed.new(fault: 'a frame sent again without limit',
             anchor: 'when Resent < ?RESENDS,', replacement: 'when Resent >= 0,',
             failure: failed('retry_limits'))
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    pristine = File.read(File.join(ROOT, SAE))
    SEEDS.each do |seed|
      assert_equal 1, pristine.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ SAE => pristine.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  # Runs erx_sae's EUnit cases against erx and erx_wifi with the given sources
  # replaced; the output and status.
  def eunit(replaced)
    Dir.mktmpdir('erx-sae-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_wifi], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test([erx_sae_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
