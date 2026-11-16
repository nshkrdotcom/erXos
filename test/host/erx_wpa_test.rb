# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The supplicant's cores, erx_wpa_kdf and erx_wpa_key (docs/design-wifi.md, "The
# supplicant" and "Verification"): their EUnit cases, the published vectors among
# them, on stock's emulator (ERX_ERL and ERX_ERLC), then the same cases against a core
# with one seeded fault each, which must fail the case named for it.
class ErxWpaTest < Minitest::Test
  KDF = 'erlang/apps/erx_wifi/src/erx_wpa_kdf.erl'
  KEY = 'erlang/apps/erx_wifi/src/erx_wpa_key.erl'
  PACKED = 'build/gen/erlang/apps/erx/src/generated/erx_abi_packed.erl'
  TESTS = %w[test/erlang/erx_wpa_kdf_tests.erl test/erlang/erx_wpa_key_tests.erl].freeze
  ROOT = File.expand_path('../..', __dir__)

  Seed = Data.define(:fault, :path, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "the PTK's address order reversed", path: KDF,
             anchor: 'Context = <<(min(Aa, Spa))/binary, (max(Aa, Spa))/binary,',
             replacement: 'Context = <<(max(Aa, Spa))/binary, (min(Aa, Spa))/binary,',
             failure: /pairwise_keys_match_the_kdf_sha256_vector_test_.*failed/m),
    Seed.new(fault: "KDF-SHA256's length left out of its blocks", path: KDF,
             anchor: 'Context/binary, Bits:16/little>>', replacement: 'Context/binary>>',
             failure: /pairwise_keys_match_the_kdf_sha256_vector_test_.*failed/m),
    Seed.new(fault: "the unwrap's index t off by one", path: KDF,
             anchor: '(Ai bxor (N * J + I))', replacement: '(Ai bxor (N * J + I - 1))',
             failure: /unwrap_matches_rfc3394_test_.*failed/m),
    Seed.new(fault: "the key data length's bound by the body dropped", path: KEY,
             anchor: "    require(?ERX_EAPOL_KEY_SIZE + DataLength =< ?EAPOL_HEADER + BodyLength, data_length),\n",
             replacement: '', failure: /each_malformed_frame_fails_with_its_rule_test_.*failed/m),
    Seed.new(fault: "key data read past the padding's start", path: PACKED,
             anchor: "header(wpa_key_data, <<221:8, 0:8, _/binary>>) ->\n    stop;\n",
             replacement: '', failure: /key_data_padding_ends_the_elements_test_.*failed/m),
    Seed.new(fault: "the IGTK's key id bound dropped", path: KEY,
             anchor: '    require(Id >= ?ERX_WPA_IGTK_KEY_ID_MIN andalso Id =< ?ERX_WPA_IGTK_KEY_ID_MAX, {key_id, igtk}),',
             replacement: '    ok,', failure: /key_data_refuses_malformed_kdes_test_.*failed/m)
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    Erx::Generated.ensure(root: ROOT)
    SEEDS.each do |seed|
      text = File.read(File.join(ROOT, seed.path))
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ seed.path => text.sub(seed.anchor, seed.replacement) })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  # Runs both modules' EUnit cases against erx and erx_wifi with the given sources
  # replaced; the output and status.
  def eunit(replaced)
    Dir.mktmpdir('erx-wpa-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_wifi], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test([erx_wpa_kdf_tests, erx_wpa_key_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
