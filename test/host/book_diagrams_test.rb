# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/book_diagrams'

# The book site's diagram step (docs/design-book-site.md, "The diagram step"
# and "Tests"): the reply it accepts, the refusal that names a diagram's file
# and line and, from the packages `tools/erx fetch` installed, the driver run
# under Node: results in order with a failure among them, the kinds the import
# leaves out refused, the same bytes from two runs, and the library's own
# output, without erXos's options, equal to the unmodified 1.1.3 package's.
# The tests that run Node skip, saying so, when the packages are not installed.
class BookDiagramsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Diagrams = Erx::Book::Diagrams
  GOLDENS = File.join(ROOT, 'test/fixtures/book_diagrams')
  GOLDEN_NAMES = %w[flow-dense flow-lr flow-tb seq-long seq-short state].freeze
  # The options without the three erXos adds, so the library draws as upstream does.
  UPSTREAM_OPTIONS = Diagrams::OPTIONS.except('charWidth', 'labelSize', 'groupTitle').freeze
  DRAWING = { 'svg' => '<svg/>' }.freeze

  def failure(line) = { 'error' => { 'stage' => 'render', 'message' => 'no', 'line' => line } }

  def test_the_reply_is_versions_and_one_result_per_diagram
    reply = JSON.generate('versions' => { 'node' => '26.13.0' }, 'results' => [DRAWING, failure(nil)])
    assert_equal [{ 'node' => '26.13.0' }, [DRAWING, failure(nil)]], Diagrams.reply(reply, count: 2)
    [
      JSON.generate('versions' => { 'node' => '26.13.0' }, 'results' => [DRAWING]),
      JSON.generate('results' => [DRAWING, DRAWING]),
      JSON.generate('versions' => { 'node' => '26.13.0' }, 'results' => [DRAWING, { 'svg' => 1 }]),
      JSON.generate('versions' => { 'node' => '26.13.0' },
                    'results' => [DRAWING, { 'error' => { 'stage' => 'layout', 'message' => 'no', 'line' => nil } }]),
      JSON.generate('versions' => { 'node' => '26.13.0' }, 'results' => [DRAWING, DRAWING.merge(failure(1))])
    ].each { |bad| assert_raises(Erx::Error, bad) { Diagrams.reply(bad, count: 2) } }
  end

  # Seeded fault: report the fence's line without the error's own line.
  def test_the_refusal_names_the_first_failed_diagrams_file_and_line
    diagrams = [10, 20, 30].map { |line| Diagrams::Diagram.new(file: "docs/book/#{line}.md", line: line, source: '') }
    assert_nil Diagrams.refusal(diagrams, [DRAWING, DRAWING, DRAWING])
    assert_equal 'docs/book/20.md:23: the diagram failed at its render stage: no',
                 Diagrams.refusal(diagrams, [DRAWING, failure(3), failure(nil)])
    assert_equal 'docs/book/20.md:20: the diagram failed at its render stage: no',
                 Diagrams.refusal(diagrams, [DRAWING, failure(nil), DRAWING])
  end

  # Seeded fault: let the driver stop at the first error, so the third result is missing.
  def test_a_failed_diagram_is_a_result_and_the_driver_goes_on
    sources = ["graph TD\n  A --> B\n", "graph sideways\n  A --> B\n", "sequenceDiagram\n  A->>B: hi\n"]
    _, results = draw(sources)
    assert_includes results[0].fetch('svg'), '<svg'
    assert_equal %w[line message stage], results[1].fetch('error').keys.sort
    assert_equal 'render', results[1].fetch('error').fetch('stage')
    assert_includes results[2].fetch('svg'), '<svg'
    diagrams = sources.each_with_index.map do |source, index|
      Diagrams::Diagram.new(file: 'docs/book/01-x.md', line: 10 * (index + 1), source: source)
    end
    error = assert_raises(Erx::Error) { Diagrams.render(diagrams, root: ROOT, runner: runner) }
    assert_match(/\Adocs\/book\/01-x\.md:20: the diagram failed at its render stage: /, error.message)
  end

  def test_the_kinds_the_import_leaves_out_are_refused
    sources = ["classDiagram\n  A <|-- B\n", "erDiagram\n  A ||--o{ B : has\n", "xychart-beta\n  bar [1, 2]\n",
               "pie\n  \"a\" : 1\n"]
    _, results = draw(sources)
    results.each_with_index do |result, index|
      assert_equal 'render', result.dig('error', 'stage'), sources[index]
    end
    assert_includes results[0].dig('error', 'message'), 'not supported'
  end

  def test_two_runs_give_the_same_bytes
    sources = GOLDEN_NAMES.map { |name| File.read(File.join(GOLDENS, "#{name}.mmd")) }
    first, second = Array.new(2) { draw(sources, options: Diagrams::OPTIONS).last }
    assert_equal first, second
    assert(first.all? { |result| result.key?('svg') })
  end

  # The goldens are the SVG the package's own dist/index.js drew; erXos's
  # options, absent, must leave every byte of the library's output as it was.
  def test_without_erxos_options_the_library_draws_as_upstream
    sources = GOLDEN_NAMES.map { |name| File.read(File.join(GOLDENS, "#{name}.mmd")) }
    _, results = draw(sources, options: UPSTREAM_OPTIONS)
    GOLDEN_NAMES.zip(results).each do |name, result|
      assert_equal File.read(File.join(GOLDENS, "#{name}.svg")), result.fetch('svg'), name
    end
  end

  # Seeded fault: measure with the width table when charWidth is set.
  def test_char_width_measures_every_character_at_one_advance
    sources = %w[iiiiiiiiiiiiiiiiiiii WWWWWWWWWWWWWWWWWWWW].map { |label| "graph TD\n  A[#{label}]\n" }
    fixed = draw(sources, options: UPSTREAM_OPTIONS.merge('charWidth' => 0.6)).last.map { |result| node_width(result) }
    # 20 characters at 13 px, the library's node label size, plus 0.15 em, plus 20 px of padding each side.
    assert_in_delta (20 * 13 * 0.6) + (0.15 * 13) + 40, fixed.first, 0.01
    assert_equal fixed.first, fixed.last
    table = draw(sources, options: UPSTREAM_OPTIONS).last.map { |result| node_width(result) }
    assert_operator table.first, :<, table.last
  end

  def test_the_driver_refuses_a_malformed_request
    bundle, = installed { Diagrams.bundle(root: ROOT, runner: runner) }
    Dir.mktmpdir('erx-book-request') do |directory|
      input = File.join(directory, 'request.json')
      File.write(input, JSON.generate('options' => {}, 'diagrams' => [1]))
      assert_raises(Erx::CommandError) do
        runner.run(['node', '--permission', "--allow-fs-read=#{bundle}", bundle], name: 'book-diagrams-malformed',
                   deadline: 60, chdir: directory, env: Erx::WebBuild::OFFLINE_ENV, stdin: input,
                   stdout: File.join(directory, 'reply.json'))
      end
    end
  end

  private

  def runner = @runner ||= Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  # The width of the first rect of a drawing, which for a one-node flowchart is the node.
  def node_width(result) = Float(result.fetch('svg')[/<rect [^>]*? width="([0-9.]+)"/, 1])

  def draw(sources, options: Diagrams::OPTIONS)
    installed { Diagrams.draw(sources, root: ROOT, runner: runner, options: options) }
  end

  def installed
    skip "the book's diagram packages are not installed; run `tools/erx fetch`" unless
      Erx::WebBuild.fetched?(root: ROOT, packages: Diagrams::PACKAGES)
    yield
  end
end
