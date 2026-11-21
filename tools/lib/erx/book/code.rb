# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'strscan'
require_relative 'html'

module Erx
  module Book
    # Highlighting for the four languages the book tags: comments and string
    # literals only, in two muted tones, as a printed book sets code
    # (docs/design-book-site.md, "Code"). Everything else stays text.
    module Code
      # Per language, the token kinds in the order they are tried at each
      # position: the first pattern that matches there wins.
      DOUBLE = /"(?:\\.|[^"\\])*"/m
      LANGUAGES = {
        'c' => { comment: %r{/\*.*?\*/|//[^\n]*}m, string: Regexp.union(DOUBLE, /'(?:\\.|[^'\\\n])+'/) },
        'erlang' => { comment: /%[^\n]*/, string: Regexp.union(DOUBLE, /\$\\?./m) },
        'ruby' => { comment: /(?<![^\s])#[^\n]*/, string: Regexp.union(DOUBLE, /'(?:\\.|[^'\\])*'/m) },
        'sh' => { comment: /(?<![^\s])#[^\n]*/, string: Regexp.union(DOUBLE, /'[^']*'/) }
      }.freeze
      CLASSES = { comment: 'co', string: 'st' }.freeze

      module_function

      def language?(name) = LANGUAGES.key?(name)

      # text as Html, each comment and string literal in a span of its class.
      def highlight(language, text)
        patterns = LANGUAGES.fetch(language)
        scanner = StringScanner.new(text)
        parts = []
        plain = +''
        until scanner.eos?
          kind, token = patterns.lazy.filter_map { |name, pattern| (match = scanner.check(pattern)) && [name, match] }.first
          if kind
            parts << plain << Html.tag('span', { class: CLASSES.fetch(kind) }, token)
            plain = +''
            scanner.pos += token.bytesize
          else
            plain << scanner.getch
          end
        end
        Html.join(*parts, plain)
      end
    end
  end
end
