# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'runner'
require_relative 'source_text'
require_relative 'bounded_file'

module Erx
  module ArchTerms
    GENERIC_ROOTS = %w[kernel include/erx liberx runtime system].freeze
    BINDING_ROOTS = %w[kernel/arch/ kernel/platform/ include/erx/arch/ include/erx/hw/
                       liberx/arch/ runtime/arch/ system/arch/].freeze
    module_function

    def parse(bytes)
      unless bytes.is_a?(String) && bytes.bytesize <= 64 * 1024 && bytes.ascii_only?
        raise Error, 'architecture term policy must be bounded ASCII'
      end
      entries = bytes.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }.map { |line| entry(line) }
      # A term declared twice in one kind, in any case, would let one line undo the other's case.
      unless entries.size.between?(1, 4096) && entries.map { |_, kind, term| [kind, term.downcase] }.uniq.size == entries.size
        raise Error, 'architecture term policy requires 1..4096 unique entries'
      end
      Regexp.union(entries.map { |sensitive, kind, term| term_pattern(sensitive, kind, term) }).freeze
    end

    # One policy line, `[case-sensitive] word|prefix|instruction TERM`, as
    # [sensitive, kind, term]. A term matches in any case unless the line
    # says case-sensitive, so a mnemonic such as SVC can stay upper case
    # while the lower-case name it spells is free.
    def entry(line)
      match = /\A(case-sensitive )?(word|prefix|instruction) ([A-Za-z][A-Za-z0-9_-]{0,127})\z/.match(line)
      raise Error, 'invalid architecture term policy entry' unless match
      match.captures
    end

    # Only letters and digits bound a term, so `_` and `/` delimit it. An
    # instruction is its mnemonic followed by blanks and an operand, `#imm`
    # or a number, as an assembler takes it.
    def term_pattern(sensitive, kind, term)
      right = { 'word' => '(?![A-Za-z0-9])', 'prefix' => '', 'instruction' => '[ \t]+[#0-9]' }.fetch(kind)
      Regexp.new("(?<![A-Za-z0-9])#{Regexp.escape(term)}#{right}", sensitive ? nil : Regexp::IGNORECASE)
    end
    private_class_method :entry, :term_pattern

    def binding_path?(relative)
      BINDING_ROOTS.any? { |prefix| relative.start_with?(prefix) } ||
        relative.match?(/\Aliberx\/backend\/[^\/]+\/arch\//)
    end

    def inputs(root:)
      sources = GENERIC_ROOTS.flat_map do |directory|
        Dir.glob(File.join(root, directory, '**/*')).select do |path|
          relative = path.delete_prefix(root + '/')
          !binding_path?(relative) && File.file?(path) && SourceText.source?(relative, bytes: ''.b)
        end
      end
      documents = Dir.glob(File.join(root, 'docs/design*.md')).reject do |path|
        File.basename(path).start_with?('design-arch-') || File.basename(path) == 'design-platforms.md'
      end
      (sources + documents).sort
    end

    def check(root:)
      root = File.expand_path(root)
      declarations = Dir.glob(File.join(root, 'hw/arch_terms/*.txt')).sort
      raise Error, 'no architecture term policies found' if declarations.empty?
      pattern = Regexp.union(declarations.map { |path| parse(BoundedFile.read(path, maximum: 64 * 1024)) })
      violations = inputs(root: root).flat_map do |path|
        bytes = BoundedFile.read(path, maximum: 32 * 1024 * 1024).dup.force_encoding(Encoding::UTF_8)
        raise Error, 'generic source is not UTF-8' unless bytes.valid_encoding?
        bytes.lines.each_with_index.map do |line, index|
          match = pattern.match(line)
          "#{path.delete_prefix(root + '/')}:#{index + 1}: #{match[0]}" if match
        end.compact
      end
      raise Error, "architecture terms outside binding layers:\n#{violations.join("\n")}" unless violations.empty?
      true
    rescue SystemCallError => error
      raise Error, "cannot check architecture terms: #{error.message}"
    end
  end
end
