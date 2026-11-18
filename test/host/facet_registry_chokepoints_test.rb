# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The facet registry's chokepoints (docs/design-system.md, "Facets a configured domain
# serves"): only erx_facets names the registry's persistent term, so the shape of a
# facet is known in one module, and only the registry's two writers, the connection
# agent and the domain service, call erx_facets:install/1, so no other module of a
# domain installs a facet or the rights of one.
class FacetRegistryChokepointsTest < Minitest::Test
  include ChokepointsHelper

  RULES = %w[facet-registry facet-registry-writers].freeze
  OWNER = 'otp/erts/preloaded/src/erx_facets.erl'
  WRITERS = %w[erlang/apps/erx/src/erx_connections.erl erlang/apps/erx_domain/src/erx_domain_srv.erl].freeze
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

  def test_every_spelling_of_the_writer_outside_the_writers_is_refused
    {
      'a remote call' => "f(F) -> erx_facets:install(F).\n",
      'a fun' => "f() -> fun erx_facets:install/1.\n",
      'a pair' => "f() -> {erx_facets, install}.\n",
      'an apply' => "f(F) -> apply(erx_facets, install, [F]).\n",
      'an import' => "-import(erx_facets, [install/1]).\n",
      'a macro naming the module' => "-define(REGISTRY, erx_facets).\n"
    }.each do |form, source|
      assert_equal [['facet-registry-writers', OTHER, 1]], found(OTHER => source), form
    end
  end

  def test_the_owner_the_writers_and_the_readers_pass
    assert_empty found(OWNER => "registry() -> persistent_term:get({erx, facets}, \#{}).\n")
    WRITERS.each { |writer| assert_empty found(writer => "f(F) -> ok = erx_facets:install(\#{data => F}).\n") }
    assert_empty found(OTHER => "%% {erx, facets} and erx_facets:install/1 in a comment are not code\n" \
                                "f() -> erx_facets:find(data), erx_facets:table([]), \"{erx, facets}\",\n" \
                                "       {erx_facets, \#{}, []}, {erx_facets_install, 1, data, self()}.\n")
  end
end
