# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'runner'
require_relative 'bounded_file'

module Erx
  # Every `FDn` that CLAUDE.md, TODO.md or a document under docs/ cites names a row of
  # the downsides table in docs/design-fiasco.md, and no row number is used twice.
  # The rows are the lines `| FDn |` of that document's downsides section alone.
  module FiascoDownsides
    TABLE_DOCUMENT = 'docs/design-fiasco.md'
    SECTION_HEADING = "## Downsides against erXos's kernel"
    ROW = /\A\| (FD\d+) \|/
    CITATION = /\bFD\d+\b/
    MAXIMUM_BYTES = 32 * 1024 * 1024

    Mention = Data.define(:id, :line)

    module_function

    # The table rows of the document's downsides section, in document order.
    def rows(text)
      in_section = false
      text.each_line.with_index(1).filter_map do |line, number|
        in_section = line.chomp == SECTION_HEADING if line.start_with?('## ')
        id = line[ROW, 1]
        Mention.new(id: id, line: number) if in_section && id
      end
    end

    # The citations in the text, in document order.
    def citations(text)
      text.each_line.with_index(1).flat_map do |line, number|
        line.scan(CITATION).map { |id| Mention.new(id: id, line: number) }
      end
    end

    # Diagnostics for a table text and the documents (path => text) that cite it; empty when sound.
    def violations(table_text:, documents:)
      table = rows(table_text)
      return ["#{TABLE_DOCUMENT}: no table rows under \"#{SECTION_HEADING}\""] if table.empty?

      by_id = table.group_by(&:id)
      repeated = by_id.values.flat_map do |same|
        same.drop(1).map { |row| "#{TABLE_DOCUMENT}:#{row.line}: #{row.id} repeats the row at line #{same.first.line}" }
      end
      dangling = documents.sort.flat_map do |path, text|
        citations(text).reject { |cited| by_id.key?(cited.id) }
                       .map { |cited| "#{path}:#{cited.line}: #{cited.id} has no row in #{TABLE_DOCUMENT}" }
      end
      repeated + dangling
    end

    def check(root:)
      root = File.expand_path(root)
      paths = %w[CLAUDE.md TODO.md] + Dir.glob('docs/*.md', base: root).sort
      documents = paths.to_h { |path| [path, read(File.join(root, path))] }
      table_text = documents.fetch(TABLE_DOCUMENT) { raise Error, "#{TABLE_DOCUMENT} is missing" }
      problems = violations(table_text: table_text, documents: documents)
      raise Error, "Fiasco downsides table problems:\n#{problems.join("\n")}" unless problems.empty?

      true
    end

    def read(path)
      text = BoundedFile.read(path, maximum: MAXIMUM_BYTES).dup.force_encoding(Encoding::UTF_8)
      raise Error, "document is not UTF-8: #{path}" unless text.valid_encoding?

      text
    end
    private_class_method :read
  end
end
