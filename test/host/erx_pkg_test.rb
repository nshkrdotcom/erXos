# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/fuzz/package_seeds'

# Runs test/erlang/erx_pkg_tests.erl, the EUnit cases of the package process at boot
# (docs/design-packaging.md, "Boot and recovery"): the file check, the recovery's plan, the
# path table and the package process under its supervisor, over a simulated medium, with
# the real admission and with registration and publication stubbed (test/erlang/erx_pkg_stubs).
# They compile from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC).
# The package files are written here through the ABI codec (Erx::PackageSeeds): three
# well-formed packages, dashboard, clock and other, each sealed by a fresh Ed25519 key
# whose public half is key.bin. erx_bytes is the host stand-in (test/erlang/host_bytes),
# whose Ed25519 check is stock's crypto.
class ErxPkgTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = (%w[erlang/apps/erx/src/erx_pkg_header.erl otp/erts/preloaded/src/erx_verity_tree.erl
                build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl
                erlang/apps/erx_domain/src/erx_app_admit.erl erlang/apps/erx_domain/src/erx_domain_core.erl
                erlang/apps/erx_domain/src/erx_ident.erl erlang/apps/erx_files/src/erx_fs_version.erl
                erlang/apps/erx_starter/src/erx_pkg_plan.erl erlang/apps/erx_starter/src/erx_pkg_io.erl
                erlang/apps/erx_starter/src/erx_pkg.erl erlang/apps/erx_starter/src/erx_pkg_sup.erl
                test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_pkg_tests.erl] +
             Dir.glob('test/erlang/erx_pkg_stubs/*.erl', base: ROOT)).map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  Seeds = Erx::PackageSeeds

  def test_package_process_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def package(name, signer:)
    Seeds.sample(name, declaration: Seeds::ERLANG.with(name: name), image_blocks: 3, tree_blocks: 1, signer: signer)
  end

  def eunit
    Dir.mktmpdir('erx-pkg-test') do |work|
      signer = Erx::AppPackage::Signer.new(OpenSSL::PKey.generate_key('ED25519'))
      File.binwrite(File.join(work, 'key.bin'), signer.public_key)
      %w[dashboard clock other].each do |name|
        File.binwrite(File.join(work, "#{name}.bin"), package(name, signer: signer).prefix)
      end
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work,
                                       '-o', work, *SOURCES, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_PKG_FILES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_pkg_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end
end
