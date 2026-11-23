# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    FACETS_DESIGN = 'docs/design-system.md#facets-a-configured-domain-serves'
    # The registry's owner, a preloaded module, since every resolution of a path reads it.
    FACETS_OWNER = 'otp/erts/preloaded/src/erx_facets.erl'
    # The registry's writer: the domain's connection agent, in every domain, the system
    # domain's included, whose installations the domain service asks of it.
    FACETS_WRITERS = %w[erlang/apps/erx/src/erx_connections.erl].freeze
    # The one caller of the system domain's agent's installation, erx_connections:grant/1.
    FACETS_INSTALLERS = %w[erlang/apps/erx_domain/src/erx_domain_srv.erl].freeze

    # The domain's facet registry's three rules. Each catches a slip, not a
    # determined bypass: a key or a call built at run time passes, as does the
    # domain service's call through its agent module's variable. Strings are
    # blanked, since a doc string may name the key or the writer; the tests'
    # modules lie outside otp/ and erlang/, so their fixtures, which put
    # registry values no writer would, are not sites.
    declare_group(
      rules: [
        # erx_facets alone knows a facet's shape, so it alone names the
        # registry's persistent term: any spelling of the key {erx, facets},
        # a macro defined as it included, is refused in every other module.
        Chokepoints::ErlangForbidden.new(
          name: 'facet-registry', rule: 'only erx_facets reads or writes the facet registry, the persistent term ' \
                                        '{erx, facets}',
          design: FACETS_DESIGN, strings: :blanked,
          pattern: /\{\s*#{ErlangText::ATOM.call('erx')}\s*,\s*#{ErlangText::ATOM.call('facets')}\s*\}/,
          sites: [FACETS_OWNER],
          seed: { 'erlang/apps/erx/src/erx_ns.erl' => "f() -> persistent_term:get({erx, facets}, \#{}).\n",
                  'otp/erts/preloaded/src/prim_file.erl' => "-define(FACETS, {'erx', facets}).\n" }
        ),
        # A facet's rights are the manifest's, which only the system domain
        # sends, so only the registry's writer, the connection agent, which
        # answers the processes waiting for an installation after each, calls
        # erx_facets:install/1.
        Chokepoints::ErlangForbidden.new(
          name: 'facet-registry-writers', rule: 'only erx_connections calls erx_facets:install/1, the facet ' \
                                                'registry\'s writer',
          design: FACETS_DESIGN, strings: :blanked,
          pattern: ErlangText.calls(module_name: 'erx_facets', functions: %w[install]),
          sites: FACETS_WRITERS,
          seed: { 'erlang/apps/erx/src/erx_ns.erl' => "f(F) -> erx_facets:install(\#{data => F}).\n",
                  'erlang/apps/erx_domain/src/erx_domain_srv.erl' => "f() -> fun erx_facets:install/1.\n" }
        ),
        # The system domain's agent installs what any process of its own
        # runtime asks, so only the domain service, which installs only the
        # grants the manifest gives, calls erx_connections:grant/1.
        Chokepoints::ErlangForbidden.new(
          name: 'facet-install-callers', rule: 'only erx_domain_srv calls erx_connections:grant/1, the system ' \
                                               'domain\'s installation of a facet',
          design: 'docs/design-system.md#waiting-for-a-grant', strings: :blanked,
          pattern: ErlangText.calls(module_name: 'erx_connections', functions: %w[grant]),
          sites: FACETS_INSTALLERS,
          seed: { 'erlang/apps/erx_domain/src/erx_domain_mints.erl' =>
                    "f(F) -> erx_connections:grant(\#{data => F}).\n",
                  'erlang/apps/erx_shell/src/erx_shell_runner.erl' => "f() -> fun erx_connections:grant/1.\n" }
        )
      ]
    )
  end
end
