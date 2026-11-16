# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/image_apps'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/package_key'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/sdk'
require_relative '../fixtures/manifest_context'

# A package added to an image (docs/design-packaging.md, "Adding an app to an image",
# Erx::ImageApps): examples/dashboard packed with an SDK exported from the tree and a
# development package key of the test's own, described by the machine's file check on the
# host, and planned into the image's file at pkg/dashboard.app and its package row, which
# the manifest check binds to the package's artifact, beside the development key the
# build context carries.
class ImageAppsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DASHBOARD = File.join(ROOT, 'examples/dashboard')

  # The domain library's planner as this test needs it: every domain, introduction and
  # session planned, since what is checked here is property 19, not property 12.
  PLANS_EVERYTHING = lambda do |view|
    { 'domains' => view.fetch('order').map { 0 }, 'introductions' => view.fetch('introductions').map { 0 },
      'sessions' => view.fetch('sessions').map { 0 } }
  end

  def self.runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  def self.scratch(prefix)
    Dir.mktmpdir(prefix).tap { |work| Minitest.after_run { FileUtils.rm_rf(work) } }
  end

  def self.sdk
    @sdk ||= begin
      directory = File.join(scratch('erx-image-apps-sdk-'), 'sdk')
      Erx::Sdk.new(root: ROOT, runner: runner, erlc: ENV.fetch('ERX_ERLC')).export(directory)
      Erx::AppPack::Sdk.new(root: directory, erlc: ENV.fetch('ERX_ERLC'))
    end
  end

  def self.signer
    @signer ||= Erx::PackageKey.ensure(directory: Erx::PackageKey.directory(home: scratch('erx-image-apps-home-')))
  end

  # The dashboard packed once from a fresh copy in a directory of its own, and described.
  def self.dashboard = @dashboard ||= pack_dashboard

  def self.pack_dashboard
    work = scratch('erx-image-apps-')
    directory = File.join(work, 'dashboard')
    FileUtils.cp_r(DASHBOARD, directory)
    path = Erx::AppPack.pack(directory: directory, sdk: sdk, signer: signer, output_directory: work, runner: runner, root: ROOT)
    Erx::ImageApps.read(path, sdk: sdk, runner: runner)
  end

  def package(name, memory: 4096) = Erx::ImageApps::Package.new(path: "/p/#{name}.app", name: name, memory: memory, sha256: "\xab".b * 32)

  def test_the_dashboard_enters_an_image_as_its_file_and_rows
    dashboard = self.class.dashboard
    bytes = File.binread(dashboard.path)
    header = Erx::AppPackage.codec.decode_layout('erx_pkg_header', bytes, prefix: true)
    assert_equal ['dashboard', Erx::AppPackage.codec.constant('app_memory_default'),
                  Digest::SHA256.digest(bytes.byteslice(0, header.fetch('header_length')))],
                 [dashboard.name, dashboard.memory, dashboard.sha256]

    key = self.class.signer.public_key
    plan = Erx::ImageApps.plan([dashboard], enable: %w[dashboard])
    assert_equal({ 'pkg/dashboard.app' => dashboard.path }, plan.entries)
    assert_equal "package dashboard\n  input @artifact.package-dashboard\n  enable YES\n", plan.rows

    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    arguments = ManifestContextFixture.arguments(codec)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: platform,
                                                           artifacts: arguments.fetch(:artifacts).merge(plan.artifacts),
                                                           development_key: key))
    # The development manifest, whose apps row takes the package.
    board = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    admitted = Erx::Manifest.admit(source: "#{board}#{plan.rows}", codec: codec,
                                   context: context, planner: PLANS_EVERYTHING)
    assert_equal [{ 'name' => 'dashboard', 'sha256' => dashboard.sha256.unpack1('H*'), 'enabled' => true }],
                 admitted.report.fetch('packages')
    assert_equal [[], true], admitted.report.values_at('signers', 'development_key')
  end

  # The same packages give the same plan, whatever order the packages come in:
  # what the image takes for them follows from its inputs alone.
  def test_the_plan_follows_from_its_inputs_alone
    one = Erx::ImageApps.plan([package('quotes'), package('clock')], enable: %w[clock])
    assert_equal one, Erx::ImageApps.plan([package('clock'), package('quotes')], enable: %w[clock])
    assert_equal %w[pkg/clock.app pkg/quotes.app], one.entries.keys
    assert_match(/\Apackage clock\n.*  enable YES\npackage quotes\n.*  enable NO\n\z/m, one.rows)
  end

  def test_a_plan_refuses_two_packages_of_a_name_and_an_enable_of_none
    error = assert_raises(Erx::Error) { Erx::ImageApps.plan([package('clock'), package('clock')], enable: []) }
    assert_match(/two packages of the image are named clock/, error.message)
    error = assert_raises(Erx::Error) { Erx::ImageApps.plan([package('clock')], enable: %w[doom]) }
    assert_match(/--enable names doom, which no added package is/, error.message)
  end

  # The file check refuses a file that is not a package, or one renamed from its app's
  # name, before the image takes it.
  def test_the_file_check_refuses_a_file_that_is_not_its_package
    work = self.class.scratch('erx-image-apps-refused-')
    junk = File.join(work, 'junk.app')
    File.binwrite(junk, "\0" * 8192)
    assert_match(/the file check refuses junk\.app: \{error,\{header,/,
                 assert_raises(Erx::Error) { Erx::ImageApps.read(junk, sdk: self.class.sdk, runner: self.class.runner) }.message)
    renamed = File.join(work, 'clock.app')
    FileUtils.cp(self.class.dashboard.path, renamed)
    assert_match(/the file check refuses clock\.app: \{error,\{name,/,
                 assert_raises(Erx::Error) { Erx::ImageApps.read(renamed, sdk: self.class.sdk, runner: self.class.runner) }.message)
  end
end
