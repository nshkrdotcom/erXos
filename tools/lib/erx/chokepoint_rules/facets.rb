# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    FACETS_DESIGN = 'docs/design-system.md#facets-a-configured-domain-serves'
    # The registry's owner, a preloaded module, since every resolution of a path reads it.
    FACETS_OWNER = 'otp/erts/preloaded/src/erx_facets.erl'
    # The registry's writers: a domain's connection agent, and the domain service, which
    # writes the system domain's own registry.
    FACETS_WRITERS = %w[erlang/apps/erx/src/erx_connections.erl erlang/apps/erx_domain/src/erx_domain_srv.erl].freeze
    ERX_FACETS = ErlangText::ATOM.call('erx_facets')
    FACETS_INSTALL = ErlangText::ATOM.call('install')

    # The domain's facet registry's two rules. Each catches a slip, not a
    # determined bypass: a key or a call built at run time passes. Strings are
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
        # sends, so only the registry's two writers install: refused outside
        # them, install/1 after erx_facets and a colon or a comma (a remote
        # call, a fun, a {Module, Function} pair), an apply of it, an import
        # from erx_facets and a macro defined as erx_facets.
        Chokepoints::ErlangForbidden.new(
          name: 'facet-registry-writers', rule: 'only erx_connections and erx_domain_srv call erx_facets:install/1, ' \
                                                'the facet registry\'s writer',
          design: FACETS_DESIGN, strings: :blanked,
          pattern: /
              #{ERX_FACETS}\s*[:,]\s*#{FACETS_INSTALL}
            | #{ErlangText::ATOM.call('apply')}\s*\(\s*#{ERX_FACETS}\s*,\s*#{FACETS_INSTALL}
            | -\s*import\s*\(\s*#{ERX_FACETS}
            | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*#{ERX_FACETS}\s*\)
          /x,
          sites: FACETS_WRITERS,
          seed: { 'erlang/apps/erx/src/erx_ns.erl' => "f(F) -> erx_facets:install(\#{data => F}).\n",
                  'erlang/apps/erx_shell/src/erx_shell_runner.erl' => "f() -> fun erx_facets:install/1.\n" }
        )
      ]
    )
  end
end
