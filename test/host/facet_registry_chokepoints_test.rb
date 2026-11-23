# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The facet registry's chokepoints (docs/design-system.md, "Facets a configured domain
# serves"): only erx_facets names the registry's persistent term, so the shape of a
# facet is known in one module; only the registry's writer, the connection agent,
# calls erx_facets:install/1, and only the domain service asks the system domain's
# agent to install (erx_connections:grant/1, docs/design-system.md, "Waiting for a
# grant"), so no other module of a domain installs a facet or the rights of one.
class FacetRegistryChokepointsTest < Minitest::Test
  include ChokepointsHelper

  RULES = %w[facet-registry facet-registry-writers facet-install-callers].freeze
  OWNER = 'otp/erts/preloaded/src/erx_facets.erl'
  WRITER = 'erlang/apps/erx/src/erx_connections.erl'
  INSTALLER = 'erlang/apps/erx_domain/src/erx_domain_srv.erl'
  OTHER = 'erlang/apps/erx/src/erx_ns.erl'

  def found(files) = erlang_found(RULES, files)

  def test_the_tree_passes
    assert_empty evaluate(RULES.map { |name| rule(name) }, erlang_tree).map(&:to_s)
  end

  def test_every_spelling_of_the_key_outside_the_owner_is_refused
    {
      'a read' => "f() -> persistent_term:get({erx, facets}, \#{}).\n",
      'a write' => "f(R) -> persistent_term:put({erx,facets}, R).\n",
      'quoted atoms' => "f() -> persistent_term:erase({'erx', 'facets'}).\n",
      'a key split across lines' => "f() -> persistent_term:get({erx,\n    facets}).\n",
      'a macro' => "-define(REGISTRY, {erx, facets}).\n"
    }.each do |form, source|
      assert_equal [['facet-registry', OTHER, 1]], found(OTHER => source), form
    end
  end

  def test_every_spelling_of_the_writer_outside_the_writer_is_refused
    [OTHER, INSTALLER].each do |file|
      ErlangCallSpellings.all('erx_facets', 'install').each do |spelling|
        assert_includes found(file => spelling.source), ['facet-registry-writers', file, spelling.line],
                        "#{spelling.form} in #{file}"
      end
    end
    ErlangCallSpellings.unrelated('erx_facets', 'install').each { |source| assert_empty found(OTHER => source), source }
  end

  def test_every_spelling_of_the_installation_outside_the_domain_service_is_refused
    [OTHER, WRITER].each do |file|
      ErlangCallSpellings.all('erx_connections', 'grant').each do |spelling|
        assert_includes found(file => spelling.source), ['facet-install-callers', file, spelling.line],
                        "#{spelling.form} in #{file}"
      end
    end
    ErlangCallSpellings.unrelated('erx_connections', 'grant').each do |source|
      assert_empty found(OTHER => source), source
    end
  end

  def test_the_owner_the_writers_and_the_readers_pass
    assert_empty found(OWNER => "registry() -> persistent_term:get({erx, facets}, \#{}).\n")
    assert_empty found(WRITER => "f(F) -> ok = erx_facets:install(\#{data => F}).\n")
    assert_empty found(INSTALLER => "f(F) -> ok = erx_connections:grant(\#{data => F}).\n")
    assert_empty found(OTHER => "%% {erx, facets} and erx_facets:install/1 in a comment are not code\n" \
                                "f() -> erx_facets:find(data), erx_facets:table([]), \"{erx, facets}\",\n" \
                                "       {erx_facets, \#{}, []}, {erx_facets_install, 1, data, self()}.\n")
  end
end
