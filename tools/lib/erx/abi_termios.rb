# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # One flag of a termios word: its name (icanon) and its bit.
    TermiosFlag = Struct.new(:name, :bit, keyword_init: true)
    # A field of contiguous bits of a termios word (csize): its mask, the
    # value its bits read as when 0, and the derived shift and last value.
    TermiosSize = Struct.new(:name, :mask, :first, keyword_init: true) do
      def shift = (mask & -mask).bit_length - 1
      def last = first + (mask >> shift)
    end
    # One word of struct termios (iflag): its flags and sizes in name order.
    TermiosWord = Struct.new(:name, :flags, :sizes, keyword_init: true)
    # One special character: its name (veof) and its index in c_cc.
    TermiosChar = Struct.new(:name, :index, keyword_init: true)
    # The termios table: the four words in struct order, the characters in
    # name order, c_cc's length and the byte written where no character is.
    TermiosTable = Struct.new(:words, :chars, :count, :unnamed, keyword_init: true)

    # The termios lines of abi/termios.txt (docs/design-live.md, "The tty").
    module Termios
      # The words of struct termios, in the order the struct holds them.
      WORDS = %w[iflag oflag cflag lflag].freeze
      # The keys of erx_tty's termios map besides the flags and sizes, which
      # no name of the table may take.
      KEYS = [*WORDS, 'cc', 'ispeed', 'ospeed'].freeze
      SECTIONS = [*WORDS, 'cc'].freeze
      NAME = /\A[a-z][a-z0-9]{0,15}\z/
      # tcflag_t is FreeBSD's unsigned int.
      WORD_MASK = 0xffff_ffff
      MAX_COUNT = 255

      module_function

      # The table, or nil when the sources have no termios lines.
      def validate(by_kind)
        declarations = by_kind.fetch('termios', [])
        return nil if declarations.empty?

        sections = declarations.to_h { |declaration| [section_of(declaration), declaration] }
        declarations.group_by { |declaration| section_of(declaration) }.each_value do |same|
          same[1]&.fail!("duplicate termios #{section_of(same[1])}")
        end
        missing = SECTIONS - sections.keys
        raise SchemaError, "the termios table has no #{missing.first} section" if missing.any?

        words = WORDS.map { |name| word(sections.fetch(name)) }
        count, unnamed, chars = cc(sections.fetch('cc'))
        names = words.flat_map { |entry| entry.flags + entry.sizes }.map(&:name) + chars.map(&:name)
        duplicate = names.tally.find { |_name, times| times > 1 }
        declarations.first.fail!("duplicate termios name #{duplicate.first}") if duplicate
        TermiosTable.new(words: words.freeze, chars: chars, count: count, unnamed: unnamed).freeze
      end

      def section_of(declaration)
        section = declaration.args.first
        declaration.fail!("unknown termios section #{section.inspect}") unless SECTIONS.include?(section)
        section
      end

      # termios FIELD and its flag and size members, which may not share a bit.
      def word(declaration)
        declaration.fail!('expected termios FIELD') unless declaration.args.size == 1
        flags = []
        sizes = []
        declaration.members.each do |line|
          case line.words
          in ['flag', name, bit] then flags << flag(line, name, bit)
          in ['size', name, mask, first] then sizes << size(line, name, mask, first)
          else line.fail!('expected flag NAME BIT or size NAME MASK FIRST')
          end
        end
        declaration.fail!("termios #{declaration.args.first} names nothing") if flags.empty? && sizes.empty?
        masks = flags.map(&:bit) + sizes.map(&:mask)
        declaration.fail!("termios #{declaration.args.first} names a bit twice") unless
          masks.sum == masks.reduce(0, :|)
        TermiosWord.new(name: declaration.args.first, flags: flags.sort_by(&:name).freeze,
                        sizes: sizes.sort_by(&:name).freeze).freeze
      end

      def flag(line, name, bit)
        value = word_value(line, bit)
        line.fail!("termios flag #{name} must be one bit") unless value.positive? && (value & (value - 1)).zero?
        TermiosFlag.new(name: name_of(line, name), bit: value).freeze
      end

      def size(line, name, mask, first)
        value = word_value(line, mask)
        low = value & -value
        line.fail!("termios size #{name} must be contiguous bits") unless value.positive? && ((value + low) & value).zero?
        start = Syntax.integer(first, line: line)
        line.fail!("termios size #{name} must start at 0 or above") if start.negative?
        TermiosSize.new(name: name_of(line, name), mask: value, first: start).freeze
      end

      # termios cc COUNT UNNAMED and its char members, each at its own index
      # below COUNT.
      def cc(declaration)
        declaration.fail!('expected termios cc COUNT UNNAMED') unless declaration.args.size == 3
        count, unnamed = declaration.args.drop(1).map { |value| Syntax.integer(value, line: declaration.line) }
        declaration.fail!("termios cc COUNT must be 1 to #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)
        declaration.fail!('termios cc UNNAMED must be a byte') unless unnamed.between?(0, 255)
        chars = declaration.members.map do |line|
          line.fail!('expected char NAME INDEX') unless line.words.size == 3 && line.words.first == 'char'
          index = Syntax.integer(line.words[2], line: line)
          line.fail!("termios char index must be below #{count}") unless index.between?(0, count - 1)
          TermiosChar.new(name: name_of(line, line.words[1]), index: index).freeze
        end
        declaration.fail!('termios cc names no character') if chars.empty?
        duplicate = chars.map(&:index).tally.find { |_index, times| times > 1 }
        declaration.fail!("duplicate termios char index #{duplicate.first}") if duplicate
        [count, unnamed, chars.sort_by(&:name).freeze]
      end

      def word_value(line, text)
        value = Syntax.integer(text, line: line)
        line.fail!("termios value #{text} is outside 32 bits") unless value.between?(0, WORD_MASK)
        value
      end

      def name_of(line, name)
        line.fail!("invalid termios name #{name.inspect}") unless name&.match?(NAME)
        line.fail!("termios name #{name} is a key of the termios map") if KEYS.include?(name)
        name.freeze
      end
    end
  end
end
