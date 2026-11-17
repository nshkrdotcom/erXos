# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/fiasco_downsides'

class FiascoDownsidesTest < Minitest::Test
  TABLE = <<~MARKDOWN
    ## Downsides against erXos's kernel

    | Row | Families |
    | --- | --- |
    | FD1 | none |
    | FD2 | SH1, P2 |
  MARKDOWN

  def setup
    @root = Dir.mktmpdir('erx-fiasco-downsides-')
    FileUtils.mkdir_p(File.join(@root, 'docs'))
    write('docs/design-fiasco.md', TABLE)
    write('CLAUDE.md', "No FD citation here.\n")
    write('TODO.md', "* [High] kernel: closes FD1 and FD2.\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def test_cited_rows_that_exist_pass
    write('docs/design-kernel.md', "See FD2.\n")
    assert Erx::FiascoDownsides.check(root: @root)
  end

  def test_citation_with_no_row_names_file_and_line
    write('docs/design-kernel.md', "fine\nsee FD3 for this\n")
    error = assert_raises(Erx::Error) { Erx::FiascoDownsides.check(root: @root) }
    assert_includes error.message, 'docs/design-kernel.md:2: FD3 has no row in docs/design-fiasco.md'
  end

  def test_citation_in_claude_md_and_todo_md_is_checked
    write('CLAUDE.md', "a\nb\nFD9\n")
    write('TODO.md', "FD8\n")
    error = assert_raises(Erx::Error) { Erx::FiascoDownsides.check(root: @root) }
    assert_includes error.message, 'CLAUDE.md:3: FD9'
    assert_includes error.message, 'TODO.md:1: FD8'
  end

  def test_duplicate_row_names_file_and_line
    write('docs/design-fiasco.md', "#{TABLE}| FD1 | none |\n")
    error = assert_raises(Erx::Error) { Erx::FiascoDownsides.check(root: @root) }
    assert_includes error.message, 'docs/design-fiasco.md:7: FD1 repeats the row at line 5'
  end

  def test_missing_table_document_is_refused
    FileUtils.rm(File.join(@root, 'docs/design-fiasco.md'))
    error = assert_raises(Erx::Error) { Erx::FiascoDownsides.check(root: @root) }
    assert_includes error.message, 'docs/design-fiasco.md is missing'
  end

  def test_table_with_no_rows_is_refused
  write('docs/design-fiasco.md', "no table\n")
  error = assert_raises(Erx::Error) { Erx::FiascoDownsides.check(root: @root) }
  assert_includes error.message, 'docs/design-fiasco.md: no table rows'
end

def test_row_outside_the_downsides_section_is_not_a_row
  write('docs/design-fiasco.md', "#{TABLE}\n## Another table\n\n| FD3 | none |\n")
  write('docs/design-kernel.md', "see FD3\n")
  error = assert_raises(Erx::Error) { Erx::FiascoDownsides.check(root: @root) }
  assert_includes error.message, 'docs/design-kernel.md:1: FD3 has no row'
  end

  private

  def write(relative, text)
    File.write(File.join(@root, relative), text)
  end
end
