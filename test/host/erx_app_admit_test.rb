# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/fuzz/package_seeds'

# Runs test/erlang/erx_app_admit_tests.erl, the EUnit cases of admission, erx_app_admit
# (docs/design-packaging.md, "Admission"), compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Each case is a package
# file written here through the encoder erx_pkg_header's tests use (Erx::PackageSeeds),
# decoded by erx_pkg_header and admitted: each refusal of the design with its accepting
# neighbour. Each fault of FAULTS replaces one passage of erx_app_admit, and the cases must
# then fail.
class ErxAppAdmitTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  MODULE = File.join(ROOT, 'erlang/apps/erx_domain/src/erx_app_admit.erl')
  SOURCES = %w[erlang/apps/erx_domain/src/erx_ident.erl erlang/apps/erx_domain/src/erx_domain_core.erl
               erlang/apps/erx/src/erx_pkg_header.erl erlang/apps/erx/src/erx_verity_tree.erl
               build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl
               test/erlang/erx_app_admit_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  # The design's seeded faults: the subset test of step 6 dropped, which admits a need the
  # row lacks; root dropped from the reserved names.
  FAULTS = {
    'step 6 dropped' => ["[] -> refuse({not_offered, Need})", '[] -> #{row => 0, windows => false}'],
    'root not reserved' => ["Name =/= <<\"root\">>", 'true']
  }.freeze

  Seeds = Erx::PackageSeeds
  Tuple = Data.define(:items)

  def test_admission_cases_pass_under_eunit
    output, status = eunit(File.read(MODULE))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_a_case
    source = File.read(MODULE)
    FAULTS.each do |name, (passage, replacement)|
      assert_equal 1, source.scan(passage).size, "#{name}: the passage occurs once"
      output, status = eunit(source.sub(passage, replacement))
      assert_match(/Failed: [1-9]\d*\./, output, "#{name} failed no case")
    end
  end

  private

  MIB = 1_048_576
  MAX_NAME = 60 # 63 bytes less the 3 of "_64", erx_domain_core's names quota as a pooled suffix
  # The app template's facet rows in the EUnit module's manifest: packages, then the apps
  # row's services display (windows), data and panel (windows).
  PACKAGES, DISPLAY, DATA, PANEL = 7, 8, 9, 10

  def package(name, needs: %w[display data], memory: 64 * MIB, edits: ->(values) { values })
    declaration = Seeds::ERLANG.with(name: name, needs: needs, memory: memory)
    Seeds.sample(name, declaration: declaration, image_blocks: 3, tree_blocks: 1, edits: edits)
  end

  # Each case: the package, the signer the file check names, the manifest and registry the
  # EUnit module calls Context, and the answer.
  def cases
    accepted + refused
  end

  def accepted
    [[package('dashboard'), 'vendor', :base, ok(1, [PACKAGES, DISPLAY, DATA], 'display')],
     [package('notes', needs: %w[data]), :development, :base, ok(1, [PACKAGES, DATA], :none)],
     [package('board', needs: %w[display panel]), :development, :base, ok(1, [PACKAGES, DISPLAY, PANEL], :none)],
     [package('kiosk', needs: []), :image, :base, ok(1, [PACKAGES], :none)],
     [package('clock'), 'vendor', :base, ok(0, [PACKAGES, DISPLAY, DATA], 'display')],
     [package('clock', needs: %w[panel]), 'vendor', :full, ok(0, [PACKAGES, PANEL], 'panel')],
     [package('a' * MAX_NAME), :development, :base, ok(1, [PACKAGES, DISPLAY, DATA], 'display')],
     [package('room_a'), :development, :base, ok(1, [PACKAGES, DISPLAY, DATA], 'display')],
     [package('min_memory', memory: Seeds.codec.constant('app_memory_min')), :development, :base,
      ok(1, [PACKAGES, DISPLAY, DATA], 'display')],
     [package('max_memory', memory: 128 * MIB), :development, :base, ok(1, [PACKAGES, DISPLAY, DATA], 'display')]]
  end

  def refused
    abi = Seeds.codec.abi_version
    min = Seeds.codec.constant('app_memory_min')
    [[package('dashboard'), :development, :no_apps, error(:no_apps)],
     [package('abi', edits: ->(values) { values.merge('abi_version' => abi + 1) }), :development, :base,
      error(Tuple.new([:abi, abi + 1, abi]))],
     # A header built for another architecture: its arch field names the string of its name.
     [package('riscv64', edits: ->(values) { values.merge('arch' => values['name']) }), :development, :base,
      error(Tuple.new([:arch, 'riscv64', Seeds::ARCH]))],
     # The first check that fails answers: an ABI mismatch before a reserved name.
     [package('alice', edits: ->(values) { values.merge('abi_version' => abi + 1) }), :development, :base,
      error(Tuple.new([:abi, abi + 1, abi]))],
     [package('root'), :development, :base, error(Tuple.new([:bad_name, 'root']))],
     [package('root_1'), :development, :base, error(Tuple.new([:bad_name, 'root_1']))],
     [package('alice_2'), :development, :base, error(Tuple.new([:bad_name, 'alice_2']))],
     [package('a' * (MAX_NAME + 1)), :development, :base, error(Tuple.new([:bad_name, 'a' * (MAX_NAME + 1)]))],
     [package('alice'), :development, :base, error(Tuple.new([:name_taken, 'alice']))],
     [package('storage'), :development, :base, error(Tuple.new([:name_taken, 'storage']))],
     [package('display'), :development, :base, error(Tuple.new([:name_taken, 'display']))],
     [package('kiosk'), 'vendor', :base, error(Tuple.new([:name_taken, 'kiosk']))],
     [package('clock'), :development, :base, error(Tuple.new([:signer_changed, 'clock']))],
     [package('dashboard'), :development, :full, error(:apps_full)],
     [package('low', memory: min - 1), :development, :base, error(Tuple.new([:memory, min - 1]))],
     [package('high', memory: (128 * MIB) + 1), :development, :base, error(Tuple.new([:memory, (128 * MIB) + 1]))],
     [package('netuser', needs: %w[display net]), :development, :base, error(Tuple.new([:not_offered, 'net']))],
     [package('pkgs', needs: %w[packages]), :development, :base, error(Tuple.new([:not_offered, 'packages']))]]
  end

  def ok(entry, rows, display) = Tuple.new([:ok, { entry: entry, rows: rows, display: display }])
  def error(reason) = Tuple.new([:error, reason])

  def term(value)
    case value
    in Tuple(items:) then "{#{items.map { |item| term(item) }.join(', ')}}"
    in Symbol then value.to_s
    in Integer then value.to_s
    in String then "<<\"#{value}\">>"
    in Array then "[#{value.map { |item| term(item) }.join(', ')}]"
    in Hash then "\#{#{value.map { |key, item| "#{key} => #{term(item)}" }.join(', ')}}"
    end
  end

  # Compiles source as erx_app_admit beside SOURCES and runs the cases: each case's file
  # bytes in a directory of its own as NNN.bin, and cases.term.
  def eunit(source)
    Dir.mktmpdir('erx-app-admit-test') do |work|
      lines = cases.each_with_index.map do |(sample, signer, context, answer), index|
        name = format('%03d_%s', index, sample.name.byteslice(0, 16))
        File.binwrite(File.join(work, "#{name}.bin"), sample.prefix)
        "{\"#{name}\", #{sample.length}, #{term(signer)}, #{context}, #{term(answer)}}.\n"
      end
      File.write(File.join(work, 'cases.term'), lines.join)
      module_file = File.join(work, 'erx_app_admit.erl')
      File.write(module_file, source)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, module_file, *SOURCES, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_ADMIT_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_app_admit_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end
end
