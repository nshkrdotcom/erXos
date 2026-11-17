# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_c'
require_relative 'abi_signals'
require_relative 'abi_termios'

module Erx
  module ABI
    # erXos's musl's headers of numbers the ABI files state: the signal
    # numbers of abi/signals.txt (docs/design-programs.md, "Signal numbers"),
    # the errno numbers of abi/errno.txt ("The POSIX-lite personality") and
    # struct termios with its flags, c_cc indices and speeds, from
    # abi/termios.txt (docs/design-live.md, "The tty").
    # They land under build/gen/musl/include, which Erx::Musl searches with
    # musl's own include directories, so musl's sources and every program
    # built on musl read the one table.
    module MuslEmitter
      INCLUDE = 'musl/include'

      module_function

      def outputs(schema)
        { "#{INCLUDE}/bits/signum.h" => (signals(schema.signals) unless schema.signals.signals.empty?),
          "#{INCLUDE}/bits/errno.h" => (errnos(schema.errnos) unless schema.errnos.errnos.empty?),
          "#{INCLUDE}/bits/termios.h" => (termios(schema.termios) if schema.termios),
          "#{INCLUDE}/bits/vdisable.h" => (vdisable(schema.termios) if schema.termios) }.compact
      end

      # musl's struct termios and its numbers, included by termios.h after
      # the types: the struct, each special character's index, each word's
      # flags and sizes, and each speed as B and its rate, unsigned as
      # speed_t is.
      def termios(table)
        chars = table.chars.sort_by(&:index).map { |char| "#define #{char.name.upcase} #{char.index}" }
        words = table.words.flat_map { |word| ['', "/* c_#{word.name} */", *word_defines(word)] }
        speeds = table.rates.map { |rate| "#define B#{rate} #{rate}U" }
        header('_BITS_TERMIOS_H',
               ['#include <bits/vdisable.h>', '', "#define NCCS #{table.count}", '', *termios_struct, '',
                '/* The special characters, by their index in c_cc. */', *chars, *words, '',
                '/* The speeds a program may name: each is its rate in bits per second. */', *speeds])
      end

      # struct termios: the words in the table's order, c_cc's NCCS bytes and
      # the two speeds.
      def termios_struct
        members = [*Termios::WORDS.map { |word| "tcflag_t c_#{word};" }, 'cc_t c_cc[NCCS];',
                   *Termios::SPEEDS.map { |speed| "speed_t c_#{speed};" }]
        ['struct termios {', *members.map { |member| "\t#{member}" }, '};']
      end

      # The byte of c_cc that names no character, which unistd.h and
      # bits/termios.h both give a program, as FreeBSD's headers do.
      def vdisable(table)
        header('_BITS_VDISABLE_H', [format('#define _POSIX_VDISABLE 0x%02x', table.unnamed)])
      end

      # A word's flags and sizes in order of their lowest bit, each size's
      # mask followed by its values.
      def word_defines(word)
        flags = word.flags.map { |flag| { flag.name.upcase => flag.bit } }
        sizes = word.sizes.map { |size| { size.name.upcase => size.mask, **size.bits_by_name } }
        (flags + sizes).sort_by { |names| lowest_bit(names.values.max) }
                       .flat_map { |names| names.map { |name, bits| format('#define %s 0x%08x', name, bits) } }
      end

      def lowest_bit(bits) = bits & -bits

      # A generated header: the notice, the include guard and the lines.
      def header(guard, lines)
        [CEmitter::NOTICE, "#ifndef #{guard}", "#define #{guard}", '', *lines, '', '#endif', ''].join("\n")
      end

      # musl's signal numbers, included by bits/signal.h: the constant of
      # each signal a program may name, with the realtime range's ends; those
      # of the signals the C library keeps (SIGTHR, SIGLWP, SIGLIBRT) under
      # _BSD_SOURCE or _GNU_SOURCE, as FreeBSD defines them for __BSD_VISIBLE;
      # and _NSIG, the bits of the set a call passes.
      def signals(table)
        nameable, reserved = table.identifiers.partition { |_name, signal| signal.nameable? }
        header('_BITS_SIGNUM_H',
               [*defines(nameable), '', '/* The C library keeps these for itself: no program may catch or send one. */',
                '#if defined(_BSD_SOURCE) || defined(_GNU_SOURCE)', *defines(reserved), '#endif', '',
                "#define _NSIG #{Signals::MAX_NUMBER}"])
      end

      # musl's errno values, included by errno.h: each errno of the table and
      # each alias by its C name. strerror's table (musl/src/errno/__strerror.h)
      # is indexed by them.
      def errnos(table)
        header('_BITS_ERRNO_H',
               [*table.errnos.map { |entry| "#define #{entry.name.upcase} #{entry.number}" },
                *table.aliases.map { |alias_name, name| "#define #{alias_name.upcase} #{name.upcase}" }])
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
