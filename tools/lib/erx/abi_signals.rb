# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # One signal of the table: its name without SIG in lower case (hup,
    # rtmin+1), or nil for a reserved number that has none, its number, its
    # default action, its alias or nil, and its description, FreeBSD's
    # sys_siglist text, for a signal 1 to 31 a program may name, else nil.
    SignalEntry = Struct.new(:name, :number, :action, :alias_name, :description, keyword_init: true) do
      # A program may name it: listed, and not kept by the C library.
      def nameable? = action != 'reserved'
    end
    # The signal table: every signal in number order, each alias with the
    # name of the signal it stands for, and each named set with its signals
    # in number order.
    SignalTable = Struct.new(:signals, :aliases, :sets, keyword_init: true) do
      # The names a header defines as constants, each with the signal it
      # stands for: every name that is an identifier (hup, rtmin, but not
      # rtmin+1), in number order, then every alias (iot).
      def identifiers
        named = signals.select(&:name).to_h { |signal| [signal.name, signal] }
        named.select { |name, _signal| name.match?(Signals::NAME) }
             .merge(aliases.transform_values { |name| named.fetch(name) })
      end
    end
    # One row of the fault table: a fault kind's name and number, and the
    # signal that ends a program whose thread faults with that kind.
    FaultSignal = Struct.new(:kind, :value, :signal, keyword_init: true)

    # The signal, reserved_signal, realtime and signal_set lines of
    # abi/signals.txt (docs/design-programs.md, "Signal numbers").
    module Signals
      # Each default action with its number in the generated code; 0 is no
      # signal, so a lookup table's unlisted entries read as none.
      ACTIONS = %w[none terminate ignore stop continue reserved].each_with_index.to_h.freeze
      NAME = /\A[a-z][a-z0-9]{0,15}\z/
      SIGNAL_SHAPE = 'expected signal NAME NUMBER ACTION [alias NAME] "DESCRIPTION"'
      # FreeBSD's _SIG_MAXSIG: signal numbers are 1 to 128.
      MAX_NUMBER = 128
      # The fault_kind member that marks a space's exit record, not a fault.
      NOT_A_FAULT = 'exit'

      module_function

      def validate(by_kind)
        listed = by_kind.fetch('signal', []).map { |declaration| signal(declaration) }
        unnamed = by_kind.fetch('reserved_signal', []).map { |declaration| reserved_signal(declaration) }
        realtime = by_kind.fetch('realtime', [])
        realtime.drop(1).each { |declaration| declaration.fail!('the signal table takes one realtime line') }
        signals = (listed + unnamed + realtime.first(1).flat_map { |declaration| realtime_signals(declaration) })
                  .sort_by(&:number)
        aliases = signals.select(&:alias_name).to_h { |signal| [signal.alias_name, signal.name] }
        line = (by_kind.fetch('signal', []) + by_kind.fetch('reserved_signal', []) + realtime).first
        unique(signals.map(&:number), label: 'signal number', line: line)
        unique(signals.filter_map(&:name) + signals.filter_map(&:alias_name), label: 'signal name', line: line)
        sets = signal_sets(by_kind.fetch('signal_set', []), signals)
        SignalTable.new(signals: signals.map(&:freeze).freeze, aliases: aliases.freeze, sets: sets).freeze
      end

      # signal_set NAME SIGNAL...: a named set of signals a program may name,
      # each by its name in the table, so a protocol that carries only some
      # signals takes them from the table instead of restating them; the set's
      # signals are in number order.
      def signal_sets(declarations, signals)
        nameable = signals.select(&:nameable?).to_h { |signal| [signal.name, signal] }
        unique(declarations.map { |declaration| declaration.args.first }, label: 'signal set',
                                                                          line: declarations.first&.line)
        declarations.to_h do |declaration|
          declaration.fail!('signal_set does not take members') unless declaration.members.empty?
          name, *members = declaration.args
          declaration.fail!('expected signal_set NAME SIGNAL...') if members.empty?
          unique(members, label: "signal in set #{name}", line: declaration.line)
          listed = members.map do |member|
            nameable.fetch(member) { declaration.fail!("signal set #{name} names #{member}, no signal a program may name") }
          end
          [Syntax.identifier(name, line: declaration.line).freeze, listed.sort_by(&:number).freeze]
        end.freeze
      end

      # The fault lines (fault KIND SIGNAL) against the fault_kind enum, in
      # kind order (docs/design-programs.md, "A program's end"). The table is
      # total: every kind but exit has exactly one row, and each row names a
      # signal a program may name, so a kind added without a signal fails
      # generation.
      def faults(by_kind, types, table)
        rows = by_kind.fetch('fault', [])
        kinds = types['fault_kind']&.members
        if kinds.nil?
          rows.first&.fail!('the fault table needs the fault_kind enum')
          return [].freeze
        end
        signals = table.signals.select(&:nameable?).to_h { |signal| [signal.name, signal] }
        listed = rows.map { |declaration| fault(declaration, kinds, signals) }
        rows.zip(listed).group_by { |_row, entry| entry.kind }.each_value do |pairs|
          pairs[1]&.first&.fail!("duplicate fault kind #{pairs[1].last.kind}")
        end
        missing = kinds.keys - [NOT_A_FAULT] - listed.map(&:kind)
        raise SchemaError, "fault kind #{missing.first} has no signal in the fault table" if missing.any?

        exit_statuses(types)
        raise SchemaError, 'the fault table needs the signal kill' unless signals.key?('kill')
        listed.sort_by(&:value).freeze
      end

      # What erx_prog:status/1 reads beside the tables: exit_kind's parent,
      # and its signal above every halt status 0 to 255, so that no halt
      # reads as a signal, with every signal number below the next value.
      def exit_statuses(types)
        values = types['exit_kind']&.members || {}
        raise SchemaError, 'the fault table needs exit_kind parent and signal' unless
          values.key?('parent') && values.key?('signal')

        base = values.fetch('signal')
        clash = values.values.find { |value| value != base && value.between?(base, base + MAX_NUMBER) }
        raise SchemaError, 'exit_kind signal must exceed 255' unless base > 255
        raise SchemaError, "exit_kind value #{clash} lies among the signal statuses" if clash
      end

      def fault(declaration, kinds, signals)
        declaration.fail!('fault does not take members') unless declaration.members.empty?
        declaration.fail!('expected fault KIND SIGNAL') unless declaration.args.size == 2
        kind, name = declaration.args
        declaration.fail!("#{kind} is no fault kind") if kind == NOT_A_FAULT || !kinds.key?(kind)
        declaration.fail!("fault #{kind} names no signal a program may name") unless signals.key?(name)
        FaultSignal.new(kind: kind.freeze, value: kinds.fetch(kind), signal: signals.fetch(name)).freeze
      end

      # The constants of the table: sig and the name of each signal whose
      # name is an identifier, and of each alias (ERX_SIGHUP, ERX_SIGIOT,
      # ERX_SIGRTMIN), and each default action's number (ERX_SIG_ACTION_STOP).
      def constants(table)
        return {} if table.signals.empty?

        table.identifiers.to_h { |name, signal| ["sig#{name}", signal.number] }
             .merge(ACTIONS.transform_keys { |action| "sig_action_#{action}" })
      end

      # signal NAME NUMBER ACTION [alias NAME] "DESCRIPTION": the description
      # ends the line of every signal but a reserved one, which strsignal
      # does not describe. Model.validate admits a quoted token on a signal
      # line only last, so a quoted last token is the description and no
      # other token is quoted.
      def signal(declaration)
        declaration.fail!('signal does not take members') unless declaration.members.empty?
        words = declaration.line.tokens.drop(1)
        description = words.pop.value if words.last&.quoted
        name, number, action, keyword, alias_name, *rest = words.map(&:value)
        unless rest.empty? && (keyword.nil? || (keyword == 'alias' && alias_name))
          declaration.fail!(SIGNAL_SHAPE)
        end
        entry = SignalEntry.new(name: name_of(name, declaration), number: number_of(number, declaration),
                                action: action_of(action, declaration),
                                alias_name: alias_name && name_of(alias_name, declaration),
                                description: description)
        if entry.nameable?
          declaration.fail!("signal #{entry.name} needs its description") if description.to_s.strip.empty?
        elsif description
          declaration.fail!("reserved signal #{entry.name} takes no description")
        end
        entry
      end

      # reserved_signal NUMBER: a number the C library keeps for itself
      # that has no name.
      def reserved_signal(declaration)
        declaration.fail!('reserved_signal does not take members') unless declaration.members.empty?
        declaration.fail!('expected reserved_signal NUMBER') unless declaration.args.size == 1
        SignalEntry.new(number: number_of(declaration.args.first, declaration), action: 'reserved')
      end

      # realtime FIRST LAST ACTION: rtmin, rtmin+1 up to the middle of the
      # range, then rtmax-N down to rtmax, as sig2str names them.
      def realtime_signals(declaration)
        declaration.fail!('realtime does not take members') unless declaration.members.empty?
        declaration.fail!('expected realtime FIRST LAST ACTION') unless declaration.args.size == 3
        first, last = declaration.args.first(2).map { |value| number_of(value, declaration) }
        action = action_of(declaration.args[2], declaration)
        declaration.fail!('realtime range is empty') unless first < last
        declaration.fail!('a real-time signal is never reserved') if action == 'reserved'
        middle = (first + last) / 2
        (first..last).map do |number|
          name = if number == first then 'rtmin'
                 elsif number <= middle then "rtmin+#{number - first}"
                 elsif number == last then 'rtmax'
                 else "rtmax-#{last - number}"
                 end
          SignalEntry.new(name: name, number: number, action: action)
        end
      end

      def name_of(value, declaration)
        declaration.fail!("invalid signal name #{value.inspect}") unless value&.match?(NAME)
        value.freeze
      end

      def number_of(value, declaration)
        number = Syntax.integer(value, line: declaration.line)
        declaration.fail!("signal number must be 1 to #{MAX_NUMBER}") unless number.between?(1, MAX_NUMBER)
        number
      end

      def action_of(value, declaration)
        declaration.fail!("unknown signal action #{value.inspect}") unless ACTIONS.key?(value) && value != 'none'
        value.freeze
      end

      def unique(values, label:, line:)
        duplicate = values.tally.find { |_value, count| count > 1 }
        line.fail!("duplicate #{label} #{duplicate.first}") if duplicate
      end
    end
  end
end
