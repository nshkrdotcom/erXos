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

# erx_pkg_manifest:system_config/1, the one Erlang reader of the manifest's apps, package
# and signer records and the development key (abi/manifest.txt), on stock OTP: over the
# hand-built bytes of AbiManifestFixture.packages and its refused variants, and over the
# manifest the check packs from rows (Erx::Manifest), so the machine reads what the host
# admitted.
class ErxPkgManifestTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/generated/erx_manifest.erl
               erlang/apps/erx_starter/src/erx_pkg_manifest.erl
               test/erlang/erx_pkg_manifest_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  # Every domain, introduction and session planned: property 12 is not what is read here.
  PLANS_EVERYTHING = lambda do |view|
    { 'domains' => view.fetch('order').map { 0 }, 'introductions' => view.fetch('introductions').map { 0 },
      'sessions' => view.fetch('sessions').map { 0 } }
  end

  def test_the_reader_answers_what_the_manifest_packs
    output, status = eunit(
      'packages' => AbiManifestFixture.packages,
      'none' => AbiManifestFixture.valid,
      'release_development' => AbiManifestFixture.packages(flags: 0),
      'two_apps' => AbiManifestFixture.packages(apps: 2),
      'admitted' => admitted
    )
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

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

  def eunit(manifests)
    Dir.mktmpdir('erx-pkg-manifest-test') do |work|
      manifests.each { |name, bytes| File.binwrite(File.join(work, "#{name}.bin"), bytes) }
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, *SOURCES, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_PKG_MANIFEST_FILES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_pkg_manifest_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end
end
