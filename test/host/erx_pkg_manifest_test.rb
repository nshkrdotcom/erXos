# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/platform'
require_relative '../fixtures/abi_manifest_fixture'
require_relative '../fixtures/manifest_context'

# erx_pkg_manifest:system_config/1, the one Erlang reader of what the manifest says about
# packages (abi/manifest.txt), and erx_pkg:system_config/2, the package process's config
# from it and the domain library's app entries, on stock OTP: over the hand-built bytes of
# AbiManifestFixture.packages, its release form and its refused variants, and over the
# manifest the check packs from rows (Erx::Manifest), so the machine reads what the host
# admitted. Each fault of FAULTS replaces one passage of one source, and the cases must
# then fail.
class ErxPkgManifestTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  READER = File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated/erx_manifest.erl')
  MODULE = File.join(ROOT, 'erlang/apps/erx_starter/src/erx_pkg_manifest.erl')
  SOURCES = [READER, MODULE] +
            %w[erlang/apps/erx_starter/src/erx_pkg.erl
               test/erlang/erx_pkg_manifest_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  # Every domain, introduction and session planned: property 12 is not what is read here.
  PLANS_EVERYTHING = lambda do |view|
    { 'domains' => view.fetch('order').map { 0 }, 'introductions' => view.fetch('introductions').map { 0 },
      'sessions' => view.fetch('sessions').map { 0 } }
  end

  # A seeded fault: the passage `from` of the source `file` replaced by `to`.
  Fault = Data.define(:file, :from, :to)
  RESERVED = '[principals, domains, services, facets]'
  # The end of the release case of the generated reader's mode choice, whose fields are the
  # counts a release manifest may hold, and that case with the development key's count added.
  RELEASE_END = "'label' => <<\"root.signers.count\">>\n#{' ' * 24}}\n#{' ' * 20}],\n#{' ' * 20}1 => ["
  DEVELOPMENT_KEY = %q(#{'scope' => 'root', 'fields' => ['development_key', 'count'], 'offset' => 436, ) +
                    %q('size' => 4, 'label' => <<"root.development_key.count">>})
  # The design's seeded faults: each kind of reserved name dropped, which lets an app take a
  # row's name; the app template found by root's principal rather than the absent one; and
  # the development key accepted in a release manifest. And a facet row's grantee read
  # without its kind, which takes the system domain's packages row for the app template's.
  FAULTS = {
    'principals not reserved' => Fault.new(file: MODULE, from: RESERVED, to: '[domains, services, facets]'),
    'domains not reserved' => Fault.new(file: MODULE, from: RESERVED, to: '[principals, services, facets]'),
    'services not reserved' => Fault.new(file: MODULE, from: RESERVED, to: '[principals, domains, facets]'),
    'facets not reserved' => Fault.new(file: MODULE, from: RESERVED, to: '[principals, domains, services]'),
    'template by root' => Fault.new(file: MODULE, from: '#{principal := ?ERX_MF_NONE}', to: '#{principal := 0}'),
    'development key in a release' =>
      Fault.new(file: READER, from: RELEASE_END,
                to: RELEASE_END.sub("\n#{' ' * 24}}", "},\n#{DEVELOPMENT_KEY}")),
    'grantee kind ignored' =>
      Fault.new(file: MODULE, from: '#{grantee_kind := ?ERX_MF_GRANTEE_SESSION, grantee := Grantee,',
                to: '#{grantee := Grantee,')
  }.freeze

  def test_the_reader_answers_what_the_manifest_packs
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_a_case
    FAULTS.each do |name, fault|
      assert_equal 1, File.read(fault.file).scan(fault.from).size, "#{name}: the passage occurs once"
      output, = eunit(fault)
      assert_match(/Failed: [1-9]\d*\./, output, "#{name} failed no case")
    end
  end

  private

  def manifests
    { 'packages' => AbiManifestFixture.packages,
      'release' => AbiManifestFixture.packages(flags: 0, development: false),
      'none' => AbiManifestFixture.valid,
      'release_development' => AbiManifestFixture.packages(flags: 0),
      'two_apps' => AbiManifestFixture.packages(apps: 2),
      'no_template' => AbiManifestFixture.packages(template: false),
      'no_packages_grant' => AbiManifestFixture.packages(packages_grant: false),
      'admitted' => admitted }
  end

  # QEMU virt's development manifest with an apps row of 1 MiB and max 2 offering the
  # system domain's files service shared, the package
  # quotes and the enabled package clock, the signer ops and a development key of 7s.
  def admitted
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    arguments = ManifestContextFixture.domain_arguments(codec)
    packages = %w[clock quotes].to_h do |name|
      ["package-#{name}", { 'kind' => 'package', 'name' => name, 'memory' => 4096, 'sha256' => 'ab' * 32 }]
    end
    context = Erx::Manifest::Context.new(**arguments, platform: JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json'))),
                                                      artifacts: arguments.fetch(:artifacts).merge(packages),
                                                      development_key: "\x07".b * 32)
    board = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    source = board.sub(/^(  max_domains )(\d+)$/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).to_i + 2}" }
                  .sub(/^(  root_memory )(\d+)$/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).to_i + (1 << 20)}" }
    rows = "service shared\n  server system\n  interface files\n" \
           "apps\n  memory #{1 << 20}\n  max 2\n  services shared\n" \
           "package quotes\n  input @artifact.package-quotes\n" \
           "package clock\n  input @artifact.package-clock\n  enable YES\n" \
           "signer ops\n  key hex:#{'cd' * 32}\n"
    Erx::Manifest.admit(source: source + rows, codec: codec, context: context, planner: PLANS_EVERYTHING).bytes
  end

  # Compiles SOURCES, with fault's file replaced by its faulted copy, and runs the cases
  # over the manifests, each written as NAME.bin.
  def eunit(fault = nil)
    Dir.mktmpdir('erx-pkg-manifest-test') do |work|
      manifests.each { |name, bytes| File.binwrite(File.join(work, "#{name}.bin"), bytes) }
      sources = SOURCES.map { |path| fault&.file == path ? faulted(fault, work) : path }
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, *sources, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_PKG_MANIFEST_FILES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_pkg_manifest_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end

  # Writes fault's file with its passage replaced into work, under the same name, and
  # answers the copy's path.
  def faulted(fault, work)
    File.join(work, File.basename(fault.file)).tap do |copy|
      File.write(copy, File.read(fault.file).sub(fault.from, fault.to))
    end
  end
end
