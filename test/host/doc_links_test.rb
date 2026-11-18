# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/doc_links'

# Document links and section citations (Erx::DocLinks): the tree passes, and a
# dangling anchor, a misnamed section and the other seeded breaks each fail at
# their file and line.
class DocLinksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DOC = 'docs/design-seeded.md'
  # The fixtures spell their citations through these, so this file cites nothing itself.
  SEEDED = File.basename(DOC)
  DOCUMENT = <<~MARKDOWN
    # Seeded

    ## The part

    **A lead-in.** Its paragraph.

    | **A row** | of a table |

    ## `erx_seed`'s state: one/two

    ## The part

    ```
    # a comment in a fence
    ```
  MARKDOWN

  def found(sources, designs: {})
    documents = { DOC => DOCUMENT }.merge(sources.select { |path, _| Erx::DocLinks.document?(path) })
    Erx::DocLinks.violations(sources, documents: documents, listed: [DOC, *sources.keys], designs: designs)
                 .map { |violation| [violation.path, violation.line] }
  end

  def test_the_tree_passes
    # The files the source check lists: tracked ones and untracked ones no rule ignores.
    listing = ['git', '-C', ROOT, 'ls-files', '--cached', '--others', '--exclude-standard', '-z']
    names = IO.popen(listing, &:read).split("\0")
    checks = Erx::Checks.new(root: ROOT, runner: nil)
    own_sources = names.reject { |path| checks.send(:imported?, path) }
    assert_nil checks.send(:check_doc_links, names, own_sources)
  end

  def test_a_dangling_anchor_fails
    assert_empty found({ 'docs/design-b.md' => "See\n[the part](#{SEEDED}#the-part).\n" })
    assert_equal [['docs/design-b.md', 2]], found({ 'docs/design-b.md' => "See\n[the part](#{SEEDED}#the-parts).\n" })
  end

  def test_a_misnamed_section_fails
    assert_empty found({ 'tools/seeded.rb' => "# (docs/design-seeded.md, \"The part\")\n" })
    assert_equal [['tools/seeded.rb', 1]], found({ 'tools/seeded.rb' => "# (docs/design-seeded.md, \"The parts\")\n" })
  end

  # A name wraps across comment lines, a lead-in is a section and a table row is
  # not, and a bare name is a document in docs/.
  def test_a_name_is_a_heading_or_a_lead_in
    assert_empty found({ 'liberx/seeded.c' => "/*\n * (design-seeded.md, \"The\n * part\"), (design-seeded.md,\n" \
                                             " * \"A lead-in\")\n */\n" })
    assert_equal [['seeded.erl', 2]], found({ 'seeded.erl' => "%% x\n%% (docs/design-seeded.md, \"A row\")\n" })
  end

  # A path in a code span, a name in parentheses and a name wrapped across a
  # Ruby comment are each read.
  def test_each_form_of_a_citation_is_read
    cite = ->(spanned, parenthesised, wrapped) do
      "# `#{DOC}`, \"#{spanned}\"\n# #{DOC} (\"#{parenthesised}\")\n# (#{DOC}, \"The\n# #{wrapped}\")\n"
    end
    assert_empty found({ 'seeded.rb' => cite.call('The part', 'A lead-in', 'part') })
    assert_equal [['seeded.rb', 1], ['seeded.rb', 2], ['seeded.rb', 3]],
                 found({ 'seeded.rb' => cite.call('Gone', 'Gone', 'parts') })
  end

  # Anchors are GitHub's: punctuation dropped, spaces made hyphens, a repeat
  # numbered, and no heading read inside a fence.
  def test_anchors_are_formed_as_github_forms_them
    sources = { 'seeded.h' => "/* #{DOC}#erx_seeds-state-onetwo #{DOC}#the-part-1 */\n" }
    assert_empty found(sources)
    assert_equal [['seeded.h', 1]], found({ 'seeded.h' => "/* #{DOC}#a-comment-in-a-fence */\n" })
  end

  def test_a_link_to_a_missing_file_fails
    assert_equal [['docs/design-b.md', 1]], found({ 'docs/design-b.md' => "[gone](design-gone.md)\n" })
  end

  def test_a_rule_s_design_link_is_resolved
    assert_empty found({}, designs: { 'chokepoint rule seeded' => "#{DOC}#the-part" })
    assert_equal [['chokepoint rule seeded', nil]], found({}, designs: { 'chokepoint rule seeded' => "#{DOC}#gone" })
  end

  # A TODO item is cited by its words, which are not read.
  def test_a_todo_item_s_name_is_not_read
    assert_empty found({ 'TODO.md' => "# TODO\n", 'tools/seeded.rb' => "# (TODO.md, \"an item\")\n" })
  end
end
