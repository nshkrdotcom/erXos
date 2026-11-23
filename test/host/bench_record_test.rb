# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_record'

# The record type, its one writer's destination checks, and the percentile rule
# (docs/design-bench.md, "The record", "Profiles", "Verification").
class BenchRecordTest < Minitest::Test
  Record = Erx::BenchRecord
  REVISION = 'abcdef0123456789abcdef0123456789abcdef01'

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-bench-record-'))
    # A stand-in for the erXos repository: its main work tree and a second worktree.
    @erxos = File.join(@scratch, 'erxos')
    @second = File.join(@scratch, 'erxos-second')
    git_init(@erxos)
    git(@erxos, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'x')
    git(@erxos, 'worktree', 'add', '-q', @second)
    @history = File.join(@scratch, 'history')
    git_init(@history)
  end

  def teardown
    FileUtils.remove_entry(@scratch)
  end

  def git_init(path)
    FileUtils.mkdir_p(path)
    git(path, 'init', '-q')
  end

  def git(path, *arguments)
    _, error, status = Open3.capture3('git', '-C', path, *arguments, stdin_data: '')
    raise "git #{arguments.first} failed: #{error}" unless status.success?
  end

  def cell(benchmark: 'wake', operation: 'park-deadline', batch: 1, status: 'measured', early: 0,
           histogram: [[1000, 1016, 2000]])
    Record::Cell.new(
      benchmark: benchmark, operation: operation,
      conditions: Record::Conditions.new(load: 'idle', placement: 'service-cpu', parameters: {}, clock: 'counter',
                                         batch: batch),
      profile: Record::Profile.new(name: 'periodic', warmup: 0, samples: 2000, runs: 1),
      status: status, reason: status == 'measured' ? nil : 'test',
      counts: { 'lost' => 0, 'early' => early, 'missed' => 0 },
      detail: { 'histogram' => histogram, 'min' => 1000, 'max' => 1016 }
    )
  end

  def record(cells: [cell], date: Time.utc(2026, 11, 23, 12, 0, 0))
    Record::Record.new(
      environment: Record::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 4, system: nil, details: {}),
      subject: Record::Subject.new(revision: REVISION, dirty: false, details: {}),
      run: Record::Run.new(date: date, started_by: 'manual', load: [0.5, 0.6], host_cpus: 12, reused_from: nil),
      clock: { 'frequency_hz' => 24_000_000 }, cells: cells
    )
  end

  def write(history, **options) = Record.write(record(**options), history: history, erxos_root: @erxos)

  def test_a_record_under_a_separate_repository_is_written
    run = write(@history)
    assert_equal File.join(@history, 'bench', 'qemu-hvf-Mac16,10-4cpu', '20261123T120000Z-abcdef012345'), run
    assert File.file?(File.join(run, 'run.json'))
    assert File.file?(File.join(run, 'wake', 'park-deadline.json'))
    assert_equal Record::FORMAT, JSON.parse(File.read(File.join(run, 'run.json'))).fetch('format')
  end

  def test_a_written_record_reads_back
    run = write(@history)
    assert_equal record, Record.read(run)
  end

  def test_a_record_of_another_format_is_refused
    run = write(@history)
    path = File.join(run, 'run.json')
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('format' => 0)))
    error = assert_raises(Erx::Error) { Record.read(run) }
    assert_match(/format/, error.message)
  end

  def test_a_run_directory_is_never_written_over
    write(@history)
    assert_raises(Erx::Error) { write(@history) }
  end

  def test_a_repository_inside_a_second_worktree_is_refused
    nested = File.join(@second, 'build', 'history')
    git_init(nested)
    error = assert_raises(Erx::Error) { write(nested) }
    assert_match(/inside the erXos worktree/, error.message)
    refute File.exist?(File.join(nested, 'bench'))
  end

  def test_the_second_worktree_itself_is_refused
    error = assert_raises(Erx::Error) { write(@second) }
    assert_match(/common git directory/, error.message)
  end

  def test_a_history_root_that_links_into_the_tree_is_refused
    nested = File.join(@erxos, 'history')
    git_init(nested)
    link = File.join(@scratch, 'link')
    File.symlink(nested, link)
    assert_raises(Erx::Error) { write(link) }
    refute File.exist?(File.join(nested, 'bench'))
  end

  def test_a_bench_directory_that_links_into_a_worktree_is_refused
    target = File.join(@second, 'build')
    FileUtils.mkdir_p(target)
    File.symlink(target, File.join(@history, 'bench'))
    error = assert_raises(Erx::Error) { write(@history) }
    assert_match(/symbolic link/, error.message)
    assert_empty Dir.children(target)
  end

  def test_a_plain_directory_is_refused
    plain = File.join(@scratch, 'plain')
    FileUtils.mkdir_p(plain)
    error = assert_raises(Erx::Error) { write(plain) }
    assert_match(/top of a git work tree/, error.message)
  end

  # A second clone of erXos has its own common git directory and is in no listed
  # worktree; it shares erXos's root commit, and that is what refuses it.
  def test_a_second_clone_of_erxos_is_refused
    clone = File.join(@scratch, 'clone')
    git(@scratch, 'clone', '-q', @erxos, clone)
    error = assert_raises(Erx::Error) { write(clone) }
    assert_match(/root commit/, error.message)
    refute File.exist?(File.join(clone, 'bench'))
  end

  def test_a_clone_on_an_orphan_branch_or_shallow_is_refused
    orphan = File.join(@scratch, 'orphan')
    git(@scratch, 'clone', '-q', @erxos, orphan)
    git(orphan, 'checkout', '-q', '--orphan', 'history')
    assert_match(/root commit/, assert_raises(Erx::Error) { write(orphan) }.message)
    shallow = File.join(@scratch, 'shallow')
    git(@scratch, 'clone', '-q', '--depth', '1', "file://#{@erxos}", shallow)
    assert_match(/shallow/, assert_raises(Erx::Error) { write(shallow) }.message)
  end

  def test_a_clone_whose_head_names_a_missing_branch_is_refused
    clone = File.join(@scratch, 'dangling')
    git(@scratch, 'clone', '-q', @erxos, clone)
    git(clone, 'symbolic-ref', 'HEAD', 'refs/heads/missing')
    assert_match(/shares a root commit/, assert_raises(Erx::Error) { write(clone) }.message)
  end

  def test_a_plain_clone_is_refused_while_erxos_is_on_an_orphan_branch
    clone = File.join(@scratch, 'plain')
    git(@scratch, 'clone', '-q', @erxos, clone)
    git(@erxos, 'checkout', '-q', '--orphan', 'elsewhere')
    git(@erxos, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'y')
    assert_match(/shares a root commit/, assert_raises(Erx::Error) { write(clone) }.message)
  end

  def test_a_separate_repository_with_its_own_history_is_written
    git(@history, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty',
        '-m', 'history')
    assert File.directory?(write(@history))
  end

  def test_a_missing_root_is_refused
    error = assert_raises(Erx::Error) { write(File.join(@scratch, 'absent')) }
    assert_match(/does not exist/, error.message)
  end

  def test_names_that_are_not_declaration_names_cannot_be_built
    assert_raises(Erx::Error) { cell(benchmark: '../escape') }
    assert_raises(Erx::Error) { cell(operation: 'a/b') }
    assert_raises(Erx::Error) { cell(status: 'passed') }
  end

  def test_a_wrong_answer_is_not_measured_and_an_absent_result_has_no_summary
    assert_raises(Erx::Error) { cell(early: 1) }
    cell(status: 'failed', early: 1)
    assert_raises(Erx::Error) { cell(status: 'timed_out') }
    assert_empty cell(status: 'timed_out', histogram: []).summary
  end

  # The summary is derived from the histogram, with its sample count, never supplied.
  def test_a_summary_is_derived_from_the_histogram
    summary = cell.summary
    assert_equal 2000, summary['samples']
    assert_equal({ 'value' => 1016, 'bucket' => 17 }, summary['p50'])
    assert_equal [1000, 1016, false], summary.values_at('min', 'max', 'partial')
    assert cell(status: 'partial').summary['partial']
    assert_raises(Erx::Error) { cell(histogram: [[10, 20, 1], [15, 30, 1]]) }
  end

  def test_the_summary_in_run_json_is_the_derived_one
    run = write(@history)
    manifest = JSON.parse(File.read(File.join(run, 'run.json')))
    assert_equal 2000, manifest.fetch('cells').first.fetch('summary').fetch('samples')
  end

  def test_nothing_is_made_inside_a_worktree_at_the_history_roots_bench
    git(@erxos, 'worktree', 'add', '-q', '--detach', File.join(@history, 'bench'))
    assert_raises(Erx::Error) { write(@history) }
    assert_equal ['.git'], Dir.children(File.join(@history, 'bench'))
  end

  # n samples, one to a bucket of one tick, so the sample of rank r reports r.
  def histogram(count) = (1..count).map { |value| [value, value, 1] }

  def test_a_percentile_needs_ten_samples_above_it
    [[Record::P99, 1000, 990], [Record::P999, 10_000, 9990], [Record::P50, 20, 10]].each do |p, count, value|
      assert_equal({ 'value' => value, 'bucket' => 1 }, Record.percentile(histogram(count), p), "#{p} of #{count}")
      assert_equal({ 'unsupported' => 'too few samples' }, Record.percentile(histogram(count - 1), p),
                   "#{p} of #{count - 1}")
    end
  end

  def test_a_percentile_is_its_buckets_upper_bound
    assert_equal({ 'value' => 1063, 'bucket' => 64 }, Record.percentile([[1000, 1063, 40]], Record::P50))
  end
end
