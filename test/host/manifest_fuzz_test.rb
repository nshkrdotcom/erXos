# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/erx_manifest'

# The manifest fuzz target's C half (tools/fuzz/manifest_fuzz.c, run by
# tools/fuzz/erx_manifest.rb through tools/fuzz/manifest_verdicts.c): over the
# manifest seeds alone, unmutated, its checks of what the reader and the domain
# library admit hold. A seed the manifest check accepts, QEMU virt's development
# manifest, the Raspberry Pi 4's, the start-row seed, the windows grant's parameter rows,
# the line grant's device reference and the ble grant's identifier set among them, is a
# valid manifest, so an abort on one is a wrong expectation in the target or a library
# that misreads a valid manifest, and either stops every run of the target before its
# mutants.
class ManifestFuzzTest < Minitest::Test
  # The valid seeds, each of which the C reader must accept: those the manifest
  # check accepts, the test fixtures' empty manifest among them.
  ADMITTED = %w[valid raspi4b domains start-row session-grantee system-args-escape windows-grant line-grant ble-grant
                operations-grant empty].freeze

  def test_the_c_half_runs_clean_over_the_seeds
    seeds = Erx::ManifestSeeds.all
    Dir.mktmpdir('erx-manifest-fuzz-') do |work|
      corpus = File.join(work, 'seeds.bin')
      File.binwrite(corpus, seeds.values.map { |bytes| [bytes.bytesize].pack('N') + bytes }.join)
      output, error, status = Open3.capture3('gtimeout', '-k', '10', ErxManifestFuzz::DEADLINE_SECONDS,
                                             ErxManifestFuzz.c_program(work), corpus, stdin_data: '')
      assert status.success? && error.empty?, "the C half failed (#{status}):\n#{error}"
      verdicts = seeds.keys.zip(output.lines.map(&:chomp)).to_h
      ADMITTED.each { |name| assert_equal 'ok', verdicts.fetch(name), "the C reader refuses seed #{name}" }
    end
  end

  # Seeded faults in the target's identifier-set order (set_follows), each of which makes
  # the target refuse the ble grant's set (nus, nusb, nv), which the boot view takes, and
  # so abort on that seed: bytes compared in reverse, and a name after its extensions.
  SET_FOLLOWS_FAULTS = {
    'bytes compared in reverse' => ['return (before->bytes[at] < value->bytes[at]);', 'return (before->bytes[at] > value->bytes[at]);'],
    'a name after its extensions' => ['return (before->bytes_len < value->bytes_len);', 'return (before->bytes_len > value->bytes_len);']
  }.freeze

  # The target compares an identifier set's elements, the ble grant seed's, by its own
  # set_follows: each seeded fault of SET_FOLLOWS_FAULTS makes the target abort on that
  # seed, not time out or trip a sanitizer.
  def test_the_target_checks_an_identifier_set_order
    bytes = Erx::ManifestSeeds.all.fetch('ble-grant')
    source = File.read(File.join(ErxManifestFuzz::ROOT, 'tools/fuzz/manifest_fuzz.c'))
    Dir.mktmpdir('erx-manifest-fuzz-') do |work|
      corpus = File.join(work, 'seed.bin')
      File.binwrite(corpus, [bytes.bytesize].pack('N') + bytes)
      SET_FOLLOWS_FAULTS.each_with_index do |(name, (anchor, replacement)), index|
        assert_equal 1, source.scan(anchor).size, "the seed #{name} no longer applies"
        seeded = File.join(work, "manifest_fuzz_#{index}.c")
        File.write(seeded, source.sub(anchor, replacement))
        program = ErxManifestFuzz.c_program(File.join(work, index.to_s).tap { |dir| Dir.mkdir(dir) }, target: seeded)
        _output, _error, status = Open3.capture3('gtimeout', '-k', '10', ErxManifestFuzz::DEADLINE_SECONDS, program, corpus,
                                                 stdin_data: '')
        abort_signal = Signal.list.fetch('ABRT')
        assert status.termsig == abort_signal || status.exitstatus == 128 + abort_signal,
               "seeded fault not caught by the target's abort: #{name} (#{status})"
      end
    end
  end
end
