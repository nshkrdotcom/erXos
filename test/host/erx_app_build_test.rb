# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/app_pack'
require_relative '../../tools/lib/erx/package_key'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/sdk'

# The packer's build and seal (docs/design-packaging.md, "Building and packing") with an
# SDK exported from the tree: examples/dashboard compiled from its sources with stock's
# erlc (ERX_ERLC, which make check supplies) against the SDK's public applications,
# signed with a development package key made as the packer makes the host's, and judged
# by the file check before it is kept.
class ErxAppBuildTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DASHBOARD = File.join(ROOT, 'examples/dashboard')

  def self.sdk
    @sdk ||= begin
      work = Dir.mktmpdir('erx-app-build-sdk-')
      Minitest.after_run { FileUtils.rm_rf(work) }
      directory = File.join(work, 'sdk')
      Erx::Sdk.new(root: ROOT, runner: runner, erlc: ENV.fetch('ERX_ERLC'), compiler: ENV.fetch('ERX_CLANG'),
                    linker: ENV.fetch('ERX_LLD')).export(directory)
      Erx::AppPack::Sdk.new(root: directory, erlc: ENV.fetch('ERX_ERLC'))
    end
  end

  def self.runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  # The development package key, in a home directory of the test's own.
  def self.signer
    @signer ||= begin
      home = Dir.mktmpdir('erx-app-build-home-')
      Minitest.after_run { FileUtils.rm_rf(home) }
      Erx::PackageKey.ensure(directory: Erx::PackageKey.directory(home: home))
    end
  end

  # +deterministic keeps the host's paths out of the beams, so the same sources packed
  # from two directories give the same bytes, sealed by the development package key.
  def test_the_dashboard_packs_alike_from_any_directory_with_the_development_key
    Dir.mktmpdir('erx-app-build-') do |work|
      packages = [File.join(work, 'one/dashboard'), File.join(work, 'two/deeper/dashboard')].map do |directory|
        FileUtils.mkdir_p(File.dirname(directory))
        FileUtils.cp_r(DASHBOARD, directory)
        File.binread(pack(directory, output: File.dirname(directory)))
      end
      assert_equal packages.first, packages.last
      assert packages.first.include?(self.class.signer.public_key), 'the package is sealed by the development key'
      ebin = File.join(work, 'one/dashboard/lib/erx_dashboard/ebin')
      assert File.file?(File.join(ebin, 'erx_dashboard_view.beam'))
      assert_match(/\{modules, \[erx_dashboard, erx_dashboard_app, /, File.read(File.join(ebin, 'erx_dashboard.app')))
    end
  end

  # Every pack compiles afresh into a new ebin/, so a removed module leaves no beam
  # behind and leaves the resource file's list, whatever the files' times.
  def test_a_removed_module_leaves_ebin_on_the_next_pack
    Dir.mktmpdir('erx-app-build-') do |work|
      directory = File.join(work, 'dashboard')
      FileUtils.cp_r(DASHBOARD, directory)
      pack(directory, output: work)
      File.delete(File.join(directory, 'lib/erx_dashboard/src/erx_dashboard_sample.erl'))
      pack(directory, output: work)
      ebin = File.join(directory, 'lib/erx_dashboard/ebin')
      refute File.exist?(File.join(ebin, 'erx_dashboard_sample.beam'))
      refute_includes Erx::ErlangApps.modules_of(File.read(File.join(ebin, 'erx_dashboard.app')), label: 'erx_dashboard.app'),
                      'erx_dashboard_sample'
    end
  end

  def test_the_file_check_refuses_a_package_sealed_by_another_key
    Dir.mktmpdir('erx-app-build-') do |work|
      directory = File.join(work, 'dashboard')
      FileUtils.cp_r(DASHBOARD, directory)
      path = pack(directory, output: work)
      other = OpenSSL::PKey.generate_key('ED25519').raw_public_key
      error = assert_raises(Erx::Error) do
        Erx::AppPack.check_file(path, key: other, sdk: self.class.sdk, runner: self.class.runner)
      end
      assert_match(/the file check refuses dashboard\.app: \{error,\{untrusted,signer\}\}/, error.message)
    end
  end

  private

  def pack(directory, output:)
    Erx::AppPack.pack(directory: directory, sdk: self.class.sdk, signer: self.class.signer, output_directory: output,
                      runner: self.class.runner, root: ROOT)
  end
end
