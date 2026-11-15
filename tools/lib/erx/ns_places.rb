# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'erlang_text'
require_relative 'error'

module Erx
  # Where erx_ns mounts each tree that has a place: the clauses of erx_ns:place/1
  # (erlang/apps/erx/src/erx_ns.erl), the one table from which both a session's facet
  # mounts (mount_facets/1) and the system domain's own mounts (mount_own/2) take their
  # point (docs/design-files.md, "A facet's mount"). The command-needs check reads it to
  # see a command reach a service by path, and release_files_test to compare it with the
  # release's mount points.
  module NsPlaces
    SOURCE = 'erlang/apps/erx/src/erx_ns.erl'
    HEAD = /^place\(/
    CLAUSE = %r{^place\((?<name>[a-z][a-z0-9_]*)\) -> \{<<"(?<point>/[a-z][a-z0-9_]*)">>, }
    CATCH_ALL = /^place\(_[A-Za-z0-9_]*\) -> none\.$/

    class Error < Erx::Error; end

    module_function

    # Each name's mount point, as its clause writes it, from erx_ns.erl's text. A place/1 clause other
    # than the catch-all that is not in the one shape read here raises, as does a text
    # with no clause, so a place written another way is never skipped.
    def points(text)
      clauses = ErlangText.code(text).lines.grep(HEAD)
      raise Error, "#{SOURCE}: no place/1 clause" if clauses.empty?

      clauses.grep_v(CATCH_ALL).to_h do |clause|
        found = CLAUSE.match(clause)
        raise Error, "#{SOURCE}: a place/1 clause not in the shape read: #{clause.strip}" unless found

        [found[:name], found[:point]]
      end
    end
  end
end
