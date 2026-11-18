# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'pathname'
require 'set'

module Erx
  # Every link to a document section and every citation of one by name reaches
  # a section that exists. A section is a heading or a bold paragraph lead-in
  # (`**Name.**` opening a paragraph or a list item); a table row is not one,
  # so a citation of a table names the section that holds it. Three forms are
  # read:
  #
  # * a link, `[text](<path>.md#anchor)` in a Markdown file, whose target is
  #   relative to the linking file's directory, as GitHub resolves it: every
  #   relative target must be a file or directory of the tree, and a
  #   Markdown target's anchor one of its headings' anchors (a bare
  #   `#anchor`, one of the linking file's own);
  # * an anchored path, `<path>.md#anchor`, in any other file: a comment, a
  #   string, or a link written there;
  # * a citation by name, `<path>.md, "Name"` (also `<path>.md "Name"`,
  #   `[text](<path>.md), "Name"` and `<path>.md#anchor, "Name"`), in any file;
  #   the name may wrap across comment lines, and must name a heading or a
  #   lead-in of the document. Names compare as anchors, so case and
  #   punctuation do not matter. TODO.md and docs/todo-*.md are cited by an
  #   item's words rather than a section, so a name cited from them is not
  #   read.
  #
  # Outside a Markdown link, a path that names a directory is relative to the
  # root, and a bare name is the citing Markdown file's sibling, or else a
  # file at the root, or else a document in docs/.
  #
  # Anchors are formed as GitHub forms them (html-pipeline v2.14.3,
  # lib/html/pipeline/toc_filter.rb, TableOfContentsFilter#call): the
  # heading's text, lowercased, with every character that is not a word
  # character, a hyphen or a space dropped, and each space made a hyphen; a
  # repeated anchor gains -1, -2 and so on. A heading's text is its line with
  # code marks and link targets dropped; the documents put no other inline
  # markup in a heading.
  #
  # Not read: reference-style links (`[text][label]`), links with a title, and
  # a citation whose path is split across lines. Diagnostics carry raw names;
  # the CLI's sink escapes them.
  module DocLinks
    DOCS = 'docs'
    # Point-in-time reports, which cite sections as they stood when written.
    RESEARCH = 'docs/research-*.md'
    ITEM_LISTS = %w[TODO.md docs/todo-*.md].freeze
    # A line break inside a paragraph or a comment, with the next line's
    # comment marker.
    CONTINUATION = %r{\n[ \t]*(?:\*|//|#+|%+)?[ \t]*}
    DOC = %r{(?<![\w./-])(?<doc>(?:[\w.-]+/)*[\w-]+\.md)}
    ANCHORED = /#{DOC}#(?<anchor>[\w-]+)/
    # The gap before a cited name is atomic, so a run of blanks is matched one
    # way only.
    # After the path: an optional anchor, the close of a code span, a link
    # target when the path was the link's text, the close of a link, a comma,
    # and an opening parenthesis before the name.
    NAMED = /#{DOC}(?:#[\w-]+)?`?(?:\]\([^()\s]*\))?\)?,?(?>(?:[ \t]|#{CONTINUATION})+)\(?"(?<name>[^"]{1,160})"/
    LINK = /\]\((?<target>[^()\s]+)\)/
    # A target that leaves the tree: a URL or a mail address.
    EXTERNAL = /\A[a-z][a-z0-9+.-]*:/i
    FENCE = /\A {0,3}(?:```|~~~)/
    HEADING = /\A {0,3}\#{1,6}[ \t]+(?<text>.*?)(?:[ \t]+\#+)?[ \t]*\z/
    LEAD = /\A[ \t]*(?<item>(?:[*+-]|\d+\.)[ \t]+)?\*\*(?<lead>[^*]+)\*\*/
    LINK_TEXT = /\[([^\]]*)\]\([^)]*\)/
    PUNCTUATION = /[^\p{Word}\- ]/u

    # The sections of one document: the anchors its headings get, and the
    # names a citation may use (headings and lead-ins, in anchor form).
    Sections = Data.define(:anchors, :names) do
      def named?(name) = names.include?(DocLinks.anchor(name.split.join(' ')))
    end

    Violation = Data.define(:path, :line, :detail) do
      def to_s = "document links: #{path}#{line ? ":#{line}" : ''}: #{detail}"
    end

    module_function

    # Whether a file's links and citations are checked: any the caller lists
    # (erXos's own files) but the research records.
    def reads?(path) = !File.fnmatch?(RESEARCH, path, File::FNM_PATHNAME)

    def document?(path) = path.end_with?('.md')

    # sources: {path => text} of the citing files; documents: {path => text}
    # of every listed Markdown file; listed: every listed path; designs:
    # {label => "<path>.md#anchor"} of links held as data, such as a chokepoint
    # rule's design section.
    def violations(sources, documents:, listed:, designs: {})
      tree = Tree.new(documents, listed)
      sources.sort.flat_map { |path, text| file_violations(path, text, tree) } +
        designs.sort.filter_map { |label, target| design_violation(label, target, tree) }
    end

    # The anchor a heading's text gets, before any repeat suffix.
    def anchor(text) = text.downcase(:ascii).gsub(PUNCTUATION, '').tr(' ', '-')

    def sections(text)
      repeats = Hash.new(0)
      anchors = Set.new
      names = Set.new
      fenced = false
      previous = ''
      text.each_line(chomp: true) do |line|
        if FENCE.match?(line)
          fenced = !fenced
        elsif !fenced
          if (heading = HEADING.match(line))
            base = anchor(heading[:text].gsub(LINK_TEXT, '\1').strip)
            anchors << (repeats[base].zero? ? base : "#{base}-#{repeats[base]}")
            repeats[base] += 1
            names << base
          elsif (lead = LEAD.match(line)) && (lead[:item] || previous.strip.empty?)
            names << anchor(lead[:lead].strip)
          end
        end
        previous = line
      end
      Sections.new(anchors: anchors.freeze, names: names.freeze)
    end

    # The listing, and each document's sections, read once.
    class Tree
      def initialize(documents, listed)
        @documents = documents
        @files = listed.map { |path| path.delete_suffix('/') }.to_set
        @directories = @files.flat_map { |path| Pathname.new(path).descend.map(&:to_s)[0...-1] }.to_set
        @sections = {}
      end

      def file?(path) = @files.include?(path)

      def exists?(path) = path == '.' || file?(path) || @directories.include?(path)

      # A document's sections, or nil when the path is no listed document.
      def sections(path)
        return nil unless @documents.key?(path)

        @sections[path] ||= DocLinks.sections(@documents.fetch(path))
      end

      # The listed file a path outside a Markdown link names, cited from a
      # Markdown file in the directory `from` (nil from any other file); the
      # path itself when it names none, which the caller then reports.
      def resolve(doc, from:)
        candidates = [from && join(from, doc), doc]
        candidates << File.join(DOCS, doc) unless doc.include?('/')
        candidates.compact.find { |path| file?(path) } || doc
      end

      def join(directory, target) = Pathname.new(File.join(directory, target)).cleanpath.to_s
    end

    # Line numbers of character offsets into one text.
    class LineIndex
      def initialize(text)
        @starts = [0]
        text.scan("\n") { @starts << Regexp.last_match.end(0) }
      end

      def at(offset) = @starts.bsearch_index { |start| start > offset } || @starts.size
    end

    def file_violations(path, text, tree)
      lines = LineIndex.new(text)
      markdown = document?(path)
      found = (markdown ? link_problems(path, text, tree) : anchored_problems(text, tree)) +
              named_problems(text, tree, from: markdown ? File.dirname(path) : nil)
      found.map { |offset, detail| Violation.new(path: path, line: lines.at(offset), detail: detail) }
    end

    def design_violation(label, target, tree)
      doc, anchor = target.split('#', 2)
      resolved = tree.resolve(doc, from: nil)
      detail = if anchor
                 anchor_problem(tree, resolved, doc, anchor)
               elsif !tree.file?(resolved)
                 "names #{doc}, which is not a file of the tree"
               end
      Violation.new(path: label, line: nil, detail: detail) if detail
    end

    # Each problem found is [offset of the match, detail].
    def link_problems(path, text, tree)
      matches(text, LINK).filter_map do |match|
        target = match[:target]
        next if EXTERNAL.match?(target)

        file, anchor = target.split('#', 2)
        doc = file.empty? ? path : tree.join(File.dirname(path), file)
        detail = if !tree.exists?(doc)
                   "links to #{target}, which is not a file of the tree"
                 elsif anchor && document?(doc)
                   anchor_problem(tree, doc, file.empty? ? path : file, anchor)
                 end
        [match.begin(0), detail] if detail
      end
    end

    def anchored_problems(text, tree)
      matches(text, ANCHORED).filter_map do |match|
        detail = anchor_problem(tree, tree.resolve(match[:doc], from: nil), match[:doc], match[:anchor])
        [match.begin(0), detail] if detail
      end
    end

    def named_problems(text, tree, from:)
      matches(text, NAMED).filter_map do |match|
        doc = tree.resolve(match[:doc], from: from)
        next if ITEM_LISTS.any? { |list| File.fnmatch?(list, doc, File::FNM_PATHNAME) }

        name = match[:name].gsub(CONTINUATION, ' ').split.join(' ')
        sections = tree.sections(doc)
        detail = if sections.nil?
                   "cites #{match[:doc]}, \"#{name}\", and #{match[:doc]} is not a document of the tree"
                 elsif !sections.named?(name)
                   "cites #{match[:doc]}, \"#{name}\", which names no heading or bold lead-in"
                 end
        [match.begin(0), detail] if detail
      end
    end

    def anchor_problem(tree, doc, shown, anchor)
      sections = tree.sections(doc)
      if sections.nil?
        "links to #{shown}##{anchor}, and #{shown} is not a document of the tree"
      elsif !sections.anchors.include?(anchor)
        "links to #{shown}##{anchor}, which is no heading's anchor"
      end
    end

    def matches(text, pattern) = text.to_enum(:scan, pattern).map { Regexp.last_match }

    private_class_method :file_violations, :design_violation, :link_problems, :anchored_problems,
                         :named_problems, :anchor_problem, :matches
  end
end
