# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # One errno of the table: its protocol name (the C name in lower case,
    # einval), its number and its alias or nil.
    ErrnoEntry = Struct.new(:name, :number, :alias_name, keyword_init: true)
    # The errno table: every errno in number order, and each alias with the
    # name of the errno it stands for.
    ErrnoTable = Struct.new(:errnos, :aliases, keyword_init: true)

    # The errno lines of abi/errno.txt (docs/design-programs.md, "The
    # POSIX-lite personality"): the closed set of error names a reply of the
    # program protocol may carry.
    module Errnos
      NAME = /\Ae[a-z0-9]{1,15}\z/
      # musl's errno numbers are below 4096, the bound its system-call
      # return convention gives them.
      MAX_NUMBER = 4095

      module_function

      def validate(by_kind)
        rows = by_kind.fetch('errno', []).map { |declaration| [declaration, errno(declaration)] }
        refuse_repeats(rows, label: 'errno number') { |entry| [entry.number] }
        refuse_repeats(rows, label: 'errno name') { |entry| [entry.name, entry.alias_name].compact }
        errnos = rows.map(&:last).sort_by(&:number)
        aliases = errnos.select(&:alias_name).to_h { |entry| [entry.alias_name, entry.name] }
        ErrnoTable.new(errnos: errnos.map(&:freeze).freeze, aliases: aliases.freeze).freeze
      end

      def errno(declaration)
        declaration.fail!('errno does not take members') unless declaration.members.empty?
        name, number, keyword, alias_name, *rest = declaration.args
        unless number && rest.empty? && (keyword.nil? || (keyword == 'alias' && alias_name))
          declaration.fail!('expected errno NAME NUMBER [alias NAME]')
        end
        value = Syntax.integer(number, line: declaration.line)
        declaration.fail!("errno number must be 1 to #{MAX_NUMBER}") unless value.between?(1, MAX_NUMBER)
        ErrnoEntry.new(name: name_of(name, declaration), number: value,
                       alias_name: alias_name && name_of(alias_name, declaration))
      end

      def name_of(value, declaration)
        declaration.fail!("invalid errno name #{value.inspect}") unless value&.match?(NAME)
        value.freeze
      end

      # Fails at the second declaration that gives a value the block yields
      # for an earlier one.
      def refuse_repeats(rows, label:)
        rows.flat_map { |declaration, entry| yield(entry).map { |value| [declaration, value] } }
            .group_by(&:last).each_value do |pairs|
              pairs[1]&.then { |declaration, value| declaration.fail!("duplicate #{label} #{value}") }
            end
      end
    end
  end
end
