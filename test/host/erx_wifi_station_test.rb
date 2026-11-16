# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The station's pure parts, erx_wifi_choose and erx_wifi_memory (docs/design-wifi.md,
# "The station" and "Verification"): their EUnit cases on stock's emulator (ERX_ERL and
# ERX_ERLC), then the same cases against a core with one seeded fault each, the faults
# the design's Verification names, which must fail the case named for it.
class ErxWifiStationTest < Minitest::Test
  CHOOSE = 'erlang/apps/erx_wifi/src/erx_wifi_choose.erl'
  MEMORY = 'erlang/apps/erx_wifi/src/erx_wifi_memory.erl'
  TESTS = %w[test/erlang/erx_wifi_choose_tests.erl test/erlang/erx_wifi_memory_tests.erl].freeze
  ROOT = File.expand_path('../..', __dir__)

  Seed = Data.define(:fault, :path, :anchor, :replacement, :failure)

  # A case's name in EUnit's verbose report, marked failed on the same line.
  def self.failed(name) = /#{name}[^\n]*\*failed\*/

  SEEDS = [
    Seed.new(fault: "a block's ieee80211w 2 read as 1", path: CHOOSE,
             anchor: 'Pmf = pmf(W, Rsn, Chip),', replacement: 'Pmf = pmf(min(W, 1), Rsn, Chip),',
             failure: failed('admission_keeps_every_property')),
    Seed.new(fault: "SAE admitted by the SSID's having any secret", path: CHOOSE,
             anchor: 'own_secret(sae, #{sae := Sae}) -> Sae;',
             replacement: 'own_secret(sae, #{sae := Sae, psk := Psk}) -> Sae orelse Psk;',
             failure: failed('admission_keeps_every_property')),
    Seed.new(fault: 'an admission that drops SAE for a BSS the memory holds', path: CHOOSE,
             anchor: 'case admit(Block, Keys, Bss, Chip) of',
             replacement: 'case admit(Block, Keys, Bss, Chip#{sae_ext := maps:get(sae_ext, Chip) andalso ' \
                          'erx_wifi_memory:held(maps:get(memory, View), {Bssid, Ssid}, maps:get(now, View)) =:= none}) of',
             failure: failed('choose_keeps_every_property')),
    Seed.new(fault: 'a pick taken before the holds are applied', path: CHOOSE,
             anchor: '= Bss, {candidate, Akm, Pmf}, Priority} <- Assessed',
             replacement: '= Bss, {_, Akm, Pmf}, Priority} <- Assessed',
             failure: failed('choose_keeps_every_property')),
    Seed.new(fault: "the names unavailable read as none, `{only, SSID}` admitting an unknown SSID as open",
             path: CHOOSE, anchor: "        {none, unavailable} -> {verdict, {refused, keys_unavailable}};\n",
             replacement: "        {none, unavailable} when Want =:= {only, Ssid} -> {wanted, ?OPEN_BLOCK, unavailable};\n" \
                          "        {none, unavailable} -> {verdict, {refused, keys_unavailable}};\n",
             failure: failed('choose_keeps_every_property')),
    Seed.new(fault: "the station's marks left out of the view", path: CHOOSE,
             anchor: '{wanted, Block, keys(Ssid, Names, Marks)};', replacement: '{wanted, Block, keys(Ssid, Names, [])};',
             failure: failed('choose_keeps_every_property')),
    Seed.new(fault: "the names' mark left out of the SSID's keys, as after a restart of the WiFi domain",
             path: CHOOSE, anchor: 'sae_only => Marked orelse Mark =/= none}',
             replacement: 'sae_only => Marked orelse Mark =:= no_such_mark}',
             failure: failed('choose_keeps_every_property')),
    Seed.new(fault: "a PSK listed by the SSID's having any secret", path: CHOOSE,
             anchor: '#{psk => Psk, sae => Sae, sae_only', replacement: '#{psk => Psk orelse Sae, sae => Sae, sae_only',
             failure: failed('choose_keeps_every_property')),
    Seed.new(fault: "a memory that holds the SSID's secret at the first secret end", path: MEMORY,
             anchor: '-define(SECRET_FROM, 3).', replacement: '-define(SECRET_FROM, 1).',
             failure: failed('one_secret_end_holds_only_the_bss')),
    Seed.new(fault: 'new names that leave the secret hold in place', path: MEMORY,
             anchor: '    maps:filter(fun(Key, _) -> not is_secret(Key) end, Memory).',
             replacement: '    Memory.', failure: failed('the_ctl_names_command_ends_every_secret_hold')),
    Seed.new(fault: 'the bound applied after the count, which may drop the BSS record just counted', path: MEMORY,
             anchor: ['    Bounded = bounded(Live, Key),',
                      '    Bounded#{Key => #{count => Count, until => Now + hold(?BSS_FIRST, ?BSS_CAP, Count - 1)}}.'].join("\n"),
             replacement: '    bounded(Live#{Key => #{count => Count, until => Now + hold(?BSS_FIRST, ?BSS_CAP, Count - 1)}}, none).',
             failure: failed('a_bss_just_counted_is_held')),
    Seed.new(fault: 'a transition access point without hash-to-element refused for PSK too', path: CHOOSE,
             anchor: '{no_h2e, fun(Akm) -> Akm =/= sae orelse H2e end},',
             replacement: '{no_h2e, fun(_Akm) -> H2e orelse not lists:member(sae, Offered) end},',
             failure: failed('admission_keeps_every_property'))
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      text = File.read(File.join(ROOT, seed.path))
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ seed.path => text.sub(seed.anchor, seed.replacement) })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  # Runs the cores' EUnit cases against erx and erx_wifi with the given sources
  # replaced; the output and status.
  def eunit(replaced)
    modules = TESTS.map { |path| File.basename(path, '.erl') }.join(', ')
    Dir.mktmpdir('erx-wifi-station-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_wifi], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{modules}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
