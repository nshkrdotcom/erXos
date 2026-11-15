# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_c'
require_relative 'abi_signals'

module Erx
  module ABI
    # erXos's musl's headers of numbers the ABI files state: the signal
    # numbers of abi/signals.txt (docs/design-programs.md, "Signal numbers").
    # They land under build/gen/musl/include, which Erx::Musl searches with
    # musl's own include directories, so musl's sources and every program
    # built on musl read the one table.
    module MuslEmitter
      INCLUDE = 'musl/include'

      module_function

      def outputs(schema)
        return {} if schema.signals.signals.empty?

        { "#{INCLUDE}/bits/signum.h" => signals(schema.signals) }
      end

      # musl's signal numbers, included by bits/signal.h: the constant of
      # each signal a program may name, with the realtime range's ends; those
      # of the signals the C library keeps (SIGTHR, SIGLWP, SIGLIBRT) under
      # _BSD_SOURCE or _GNU_SOURCE, as FreeBSD defines them for __BSD_VISIBLE;
      # and _NSIG, the bits of the set a call passes.
      def signals(table)
        nameable, reserved = table.identifiers.partition { |_name, signal| signal.nameable? }
        [CEmitter::NOTICE, '#ifndef _BITS_SIGNUM_H', '#define _BITS_SIGNUM_H', '', *defines(nameable), '',
         '/* The C library keeps these for itself: no program may catch or send one. */',
         '#if defined(_BSD_SOURCE) || defined(_GNU_SOURCE)', *defines(reserved), '#endif', '',
         "#define _NSIG #{Signals::MAX_NUMBER}", '', '#endif', ''].join("\n")
      end

      # SIG and the name in upper case: a signal's own name defined as its
      # number, an alias as the constant of the signal it stands for.
      def defines(identifiers)
        identifiers.map do |name, signal|
          value = name == signal.name ? signal.number : "SIG#{signal.name.upcase}"
          "#define SIG#{name.upcase} #{value}"
        end
      end
    end
  end
end
