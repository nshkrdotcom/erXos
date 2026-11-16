# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/manifest_seeds'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'

# A facet row's parameters reach the mint (docs/design-system.md, "Facets a configured
# domain serves"): the manifest fuzz target's windows-grant seed, the display_domain
# suite's manifest with its client template's grant of the display stating pixels,
# windows and clipboard (Erx::ManifestSeeds.windows_grant), is packed by the manifest check;
# the domain library's boot view (liberx/system/dom_boot_view.c) is built from those
# bytes, and the NIF's erx_domain_served_terms
# (otp/erts/emulator/nifs/erxos/erx_domain_terms.c) turns it into
# erx_domain_lib:configured/0's terms, through the host harness
# test/fixtures/erx_domain_terms_harness.c loaded into stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies), under test/erlang/erx_facet_parameters_tests.erl:
# the grant's limits carry each parameter by name, erx_domain_mints charges the display
# the row's pixel area, and the view refuses each forged parameter row of FORGED. The
# line-grant seed (Erx::ManifestSeeds.line_grant) takes the same road: its grant's uart
# reaches the terms as the index of its UART's device row, and the manifest's reader, which
# the view reads through, refuses a uart one past the device table. Seeded faults that drop
# a parameter on the way, or admit one out of bound, must each fail a case.
class FacetParametersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  TERMS = File.join(NIFS, 'erx_domain_terms.c')
  VIEW = File.join(ROOT, 'liberx/system/dom_boot_view.c')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_domain_terms_harness.c')
  LIBRARY = %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/erx_lane.c
               liberx/backend/core/boot_manifest.c].map { |path| File.join(ROOT, path) }.freeze
  TESTS = %w[test/erlang/erx_facet_parameters_tests.erl].freeze
  LIMITS_CASE = 'the_grant_s_limits_carry_its_parameters_by_name_test'
  FORGED_CASE = 'forged_parameter_rows_are_refused_test'
  LINE_CASE = 'the_line_grant_s_uart_is_its_device_row_test'

  # The grant's packed parameter rows are windows (key 1), pixels (2) and clipboard (3), the
  # manifest's only ones, 32 bytes each: key u32 at 0, kind u32 at 4, scalar u64 at 8.
  # Each forgery edits the rows, given as an array of their bytes, and the view must refuse it.
  FORGED = {
    'undeclared' => ->(rows) { rows[2][0, 4] = [5].pack('V') },
    'out-of-order' => ->(rows) { rows[0], rows[1] = rows[1], rows[0] },
    'stated-twice' => ->(rows) { rows[1] = rows[0].dup },
    'other-kind' => ->(rows) { rows[0][4, 4] = [2].pack('V') },
    'below-its-bound' => ->(rows) { rows[1][8, 8] = [4095].pack('Q<') }
  }.freeze

  def test_a_packed_row_reaches_the_mint
    assert_match(/^  All 4 tests passed\.$/, run_cases)
  end

  # A seeded fault: the file it edits, the anchor found once there, its replacement and
  # the case that must fail on it.
  MUTANTS = {
    'the view drops a facet\'s last parameter' =>
      [VIEW, '.parameters = &parameters[first], .nparameters = facet.parameters.count };',
       '.parameters = &parameters[first], .nparameters = facet.parameters.count - (facet.parameters.count != 0) };',
       LIMITS_CASE],
    'the terms leave the parameters out' =>
      [TERMS, 'for (uint32_t at = 0; at < facet->nparameters; at++) {', 'for (uint32_t at = 0; at < 0; at++) {',
       LIMITS_CASE],
    'the view admits a value out of its bound' =>
      [VIEW, 'return (within ? NULL : "manifest: a facet parameter is outside its declared bound");', 'return ((void)within, NULL);',
       FORGED_CASE],
    'the view drops a device reference' =>
      [VIEW, 'value->index = row->index;', 'value->index = 0;', LINE_CASE],
    'the terms give a device reference\'s scalar' =>
      [TERMS, 'enif_make_uint(env, parameter->index)', 'enif_make_uint(env, (unsigned)parameter->scalar)', LINE_CASE]
  }.freeze

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, (file, anchor, replacement, catching_case)|
      source = File.read(file)
      assert_equal 1, source.scan(anchor).size, "mutant #{name} must edit exactly one place"
      output = run_cases(file => source.sub(anchor, replacement))
      assert_match(/erx_facet_parameters_tests: #{catching_case}[^\n]*\*failed\*/, output, "seeded fault not caught: #{name}")
    end
  end

  private

  def codec = @codec ||= Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
  def manifest = @manifest ||= Erx::ManifestSeeds.windows_grant(ROOT, codec)
  def line_manifest = @line_manifest ||= Erx::ManifestSeeds.line_grant(ROOT, codec)

  # The line manifest's device rows, by path, the index of the one its grant names.
  def line_uart
    view = codec.open('manifest', line_manifest)
    view.count('devices').times.find { |index| view.string(view.fetch('devices', index).fetch('path')) == Erx::ManifestSeeds::LINE_UART }
  end

  # The line manifest with its grant's uart row naming one past the device table.
  def line_past_the_table
    header = codec.open('manifest', line_manifest).header
    table = header.fetch('facet_parameters')
    device = codec.member('mf_parameter_kind', 'device')
    offset = table.fetch('count').times.map { |index| table.fetch('offset') + (index * 32) }.find do |at|
      codec.decode_layout('erx_mf_parameter', line_manifest, offset: at, prefix: true).fetch('kind') == device
    end
    row = codec.decode_layout('erx_mf_parameter', line_manifest, offset: offset, prefix: true)
    encoded = codec.encode_layout('erx_mf_parameter', row.merge('index' => header.fetch('devices').fetch('count')))
    line_manifest.b.tap { |copy| copy[offset, encoded.bytesize] = encoded }
  end

  # The manifest with its parameter rows edited by forge.
  def forged(forge)
    table = codec.open('manifest', manifest).header.fetch('facet_parameters')
    assert_equal 3, table.fetch('count')
    offset = table.fetch('offset')
    rows = Array.new(3) { |index| manifest.byteslice(offset + (index * 32), 32).b }
    forge.call(rows)
    manifest.b.tap { |copy| copy[offset, 96] = rows.join }
  end

  # The cases' output, with the harness built from sources, each path's text as given
  # and the rest of the library as checked in. The forged manifests are refused-NAME.bin.
  def run_cases(sources = {})
    Dir.mktmpdir('erx-facet-parameters-') do |work|
      File.binwrite(File.join(work, 'manifest.bin'), manifest)
      FORGED.each { |name, forge| File.binwrite(File.join(work, "refused-#{name}.bin"), forged(forge)) }
      File.binwrite(File.join(work, 'line.bin'), line_manifest)
      File.write(File.join(work, 'line-uart'), line_uart.to_s)
      File.binwrite(File.join(work, 'unreadable-device-past-the-table.bin'), line_past_the_table)
      ErlangBuild.compile(work, applications: %w[erx_domain], tests: TESTS)
      build_nif(work, sources.to_h { |path, text| [path, File.join(work, File.basename(path)).tap { |copy| File.write(copy, text) }] })
      output, = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120',
                                ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                'halt(case eunit:test(erx_facet_parameters_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                chdir: work, stdin_data: '')
      output
    end
  end

  # erx_domain_terms_harness.so in work, against the headers of the emulator ERX_ERL runs.
  def build_nif(work, copies)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    sources = [TERMS, VIEW, HARNESS, *LIBRARY].map { |path| copies.fetch(path, path) }
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17',
                                     '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
                                     *Erx::HostOs::NIF_LINK_FLAGS, '-I', NIFS, '-I', File.join(root, 'usr/include'),
                                     *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'),
                                     '-I', ROOT, '-o', File.join(work, 'erx_domain_terms_harness.so'), *sources,
                                     Erx::Generated.path('liberx/generated/abi_reader.c', root: ROOT), stdin_data: '')
    assert status.success?, output
  end
end
