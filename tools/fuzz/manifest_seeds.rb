# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/display_domain'
require_relative '../lib/erx/platform'
require_relative '../../test/fixtures/manifest_context'
require_relative '../lib/erx/abi'
require_relative '../lib/erx/json_input'
require_relative '../lib/erx/manifest'

module Erx
  # The seeds of the targets that read a system manifest: the bytes the packer writes.
  # QEMU virt's development manifest, as Phase 1's check admits it for a production image,
  # the same with configured domains (ManifestContextFixture.domain_source), the empty
  # native manifest of the structural test images, with prefixes of the first, the
  # configured domains' with its first row's boot_timeout_s 0, which the reader refuses,
  # the configured domains' with alpha's probe granted to the system principal's
  # session template, so the facet table holds a session grantee, and the same with a
  # start row for that template, left off and with its own restart intensity, and the
  # display_domain suite's manifest with its client's grant of the display stating each
  # parameter of the windows interface a facet row may, so the facet table holds parameter
  # rows, and the configured domains' with alpha granted the line on a UART of its own,
  # so a parameter row holds a device reference.
  module ManifestSeeds
    SESSION_FACET = "facet session_probe\n  grantee @session.system\n  service @service.probe\n  operations none\n" \
                    "  max_request 64\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    START_ROW = "start system\n  enable NO\n  restarts 3\n  restart_period_s 60\n"
    WINDOWS_PARAMETERS = "  parameter pixels 4194304\n  parameter windows 2\n  parameter clipboard yes\n"
    # The UART line_grant's grant names.
    LINE_UART = ManifestContextFixture::LINE_UARTS.fetch('line_a').first

    module_function

    def all
      repository = File.expand_path('../..', __dir__)
      codec = ABI::Codec.new(ABI::Generator.plan(root: repository).schema)
      fixture = ManifestContextFixture.arguments(codec)
      platform = platform_of(repository, 'qemu-virt')
      source = Platform.load(root: repository, name: 'qemu-virt').manifest_source(repository)
      context = Manifest::Context.new(**fixture, platform: platform)
      development = Manifest.admit(source: source, codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
      # A terminal escape in an argument, which the boot page's reader refuses.
      escape = Manifest.admit(source: source.sub(/^\s*system_args .*$/, '  system_args hex:2d5a1b5d323b7265766965770700'),
                              codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
      pi = Manifest.admit(source: Platform.load(root: repository, name: 'raspi4b').manifest_source(repository),
                          codec: codec, context: Manifest::Context.new(**fixture, platform: platform_of(repository, 'raspi4b')),
                          planner: ManifestContextFixture.accepting_planner)
      empty = Manifest.structural_fixture(source: File.binread(File.join(repository, 'test/fixtures/manifest_empty.txt')),
                                          codec: codec, context: Manifest::Context.new(**fixture))
      domain_context = Manifest::Context.new(**ManifestContextFixture.domain_arguments(codec), platform: platform)
      domains = Manifest.admit(source: ManifestContextFixture.domain_source(source), codec: codec,
                               context: domain_context, planner: ManifestContextFixture.accepting_planner)
      session = Manifest.admit(source: ManifestContextFixture.domain_source(source) + SESSION_FACET, codec: codec,
                               context: domain_context, planner: ManifestContextFixture.accepting_planner)
      start = Manifest.admit(source: ManifestContextFixture.domain_source(source) + SESSION_FACET + START_ROW, codec: codec,
                             context: domain_context, planner: ManifestContextFixture.accepting_planner)
      PackFuzz.prefix_seeds(development.bytes).merge('empty' => empty.bytes, 'system-args-escape' => escape.bytes,
                                                     'windows-grant' => windows_grant(repository, codec),
                                                     'line-grant' => line_grant(repository, codec),
                                                     'domains' => domains.bytes, 'session-grantee' => session.bytes,
                                                     'start-row' => start.bytes, 'raspi4b' => pi.bytes,
                                                     'boot-timeout-zero' => boot_timeout(codec, domains.bytes, 0))
    end

    # The display_domain suite's manifest, its client's grant stating WINDOWS_PARAMETERS, as
    # the check packs it over the fixture's archive with a planner that places nothing.
    def windows_grant(repository, codec)
      platform = Platform.load(root: repository, name: 'qemu-virt')
      source = DisplayDomain.manifest(platform.site_manifest_source(repository, keep: [DisplayDomain::DOMAIN]))
                            .sub("  parameter pixels #{DisplayDomain::PIXELS}\n", WINDOWS_PARAMETERS)
      arguments = ManifestContextFixture.archive_arguments(codec, boots: %w[display network pattern session storage web])
      context = Manifest::Context.new(**arguments, platform: platform_of(repository, 'qemu-virt'))
      planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
      Manifest.admit(source: source, codec: codec, context: context, planner: planner).bytes
    end

    # The configured domains' manifest (ManifestContextFixture.domain_source) on QEMU virt
    # with two more UARTs, alpha granted the line on the first
    # (ManifestContextFixture.with_line), as the check packs it.
    def line_grant(repository, codec)
      source = Platform.load(root: repository, name: 'qemu-virt').manifest_source(repository)
      grant = ManifestContextFixture.line_grant('line', '@domain.alpha', LINE_UART)
      context = Manifest::Context.new(**ManifestContextFixture.domain_arguments(codec),
                                      platform: ManifestContextFixture.line_platform(platform_of(repository, 'qemu-virt')))
      Manifest.admit(source: ManifestContextFixture.with_line(ManifestContextFixture.domain_source(source), grant),
                     codec: codec, context: context, planner: ManifestContextFixture.accepting_planner).bytes
    end

    # The platform record config/platforms/NAME.json.
    def platform_of(repository, name)
      path = "config/platforms/#{name}.json"
      JsonInput.parse(File.binread(File.join(repository, path)), max_bytes: 65_536, label: path)
    end

    # The manifest bytes with their first configured domain's boot_timeout_s set to seconds.
    def boot_timeout(codec, bytes, seconds)
      offset = codec.open('manifest', bytes).header.fetch('domains').fetch('offset')
      row = codec.decode_layout('erx_mf_domain', bytes, offset: offset, prefix: true)
      encoded = codec.encode_layout('erx_mf_domain', row.merge('boot_timeout_s' => seconds))
      bytes.b.tap { |copy| copy[offset, encoded.bytesize] = encoded }
    end
  end
end
