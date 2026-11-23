# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'stringio'
require 'tmpdir'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

# check-fuzz runs every fuzz driver in tools/fuzz and test/fuzz: a driver
# someone adds is run at the milestone gate without any other edit.
class FuzzDriversTest < Minitest::Test
  DIRECTORIES = %w[tools/fuzz test/fuzz].freeze

  # Records each command instead of running it.
  class RecordingRunner
    def initialize(commands) = @commands = commands
    def run(argv, name:, deadline:, **options) = @commands << { argv: argv, name: name, deadline: deadline, **options }
  end

  def check_fuzz_commands
    commands = []
    runner_class = Class.new { define_singleton_method(:new) { |**| RecordingRunner.new(commands) } }
    runtime = proc { |**, &block| block.call('ERX_ERL' => '/verified/erl', 'ERX_ERLC' => '/verified/erlc') }
    capture_io do
      Erx::CLI.check_fuzz([], runner_class: runner_class, runtime: runtime, c_fuzzer: proc { |**| })
    end
    commands
  end

  def helper?(path) = File.foreach(path).any? { |line| line.chomp == '# erx-gate: fuzz helper' }

  def test_check_fuzz_runs_every_fuzz_driver
    run_scripts = check_fuzz_commands.filter_map do |command|
      script = command.fetch(:argv)[1]
      script.delete_prefix("#{Erx::ROOT}/") if command.fetch(:argv)[0] == RbConfig.ruby
    end
    drivers = DIRECTORIES.flat_map { |directory| Dir.glob("#{directory}/*.rb", base: Erx::ROOT) }
                         .reject { |path| path.end_with?('_target.rb') || helper?(File.join(Erx::ROOT, path)) }
    assert_empty drivers.sort - run_scripts, 'fuzz drivers check-fuzz never runs'
  end

  def with_fuzz_tree(files)
    Dir.mktmpdir('erx-fuzz-drivers-') do |root|
      FileUtils.mkdir_p(File.join(root, 'tools/fuzz'))
      files.each { |name, body| File.write(File.join(root, 'tools/fuzz', name), body) }
      yield root
    end
  end

  def plan(files)
    with_fuzz_tree(files) { |root| Erx::FuzzDrivers.runs(root: root, seconds: 5, seed: 9, directories: %w[tools/fuzz]) }
  end

  def assert_refused(files, message)
    error = assert_raises(Erx::Error) { plan(files) }
    assert_includes error.message, message
  end

  # Adding a driver is adding its file: each kind's command, deadline and
  # name follow from its one line; helpers and native declarations run nothing.
  def test_each_declared_driver_is_planned_from_its_own_line
    runs = plan('new_parser.rb' => "# erx-gate: fuzz seeded deadline=420\n",
                'clock_fuzz.rb' => "# erx-gate: fuzz timed\n",
                'rules_fuzz.rb' => "# erx-gate: fuzz fixed\n", 'seeds.rb' => "# erx-gate: fuzz helper\n",
                'lane_target.rb' => "Erx::PackFuzz.declare_target\n")
    assert_equal [
      Erx::FuzzDrivers::Run.new('fuzz-clock', 'tools/fuzz/clock_fuzz.rb', %w[--seconds 5 --seed 9], 35),
      Erx::FuzzDrivers::Run.new('fuzz-new-parser', 'tools/fuzz/new_parser.rb', %w[--seed 9], 420),
      Erx::FuzzDrivers::Run.new('fuzz-rules', 'tools/fuzz/rules_fuzz.rb', [], Erx::FuzzDrivers::FIXED_DEADLINE)
    ], runs
  end

  # targets= reads the driver's own table, so a target added there runs.
  def test_a_driver_with_targets_runs_once_per_key_of_its_table
    body = "# erx-gate: fuzz seeded deadline=60 targets=FuzzDriversTestTable::FAULTS\n" \
           "module FuzzDriversTestTable\n  FAULTS = { 'alpha' => 1, 'beta_two' => 2 }.freeze\nend\n"
    runs = plan('multi_driver.rb' => body)
    assert_equal [['fuzz-multi-driver-alpha', %w[--target alpha --seed 9]],
                  ['fuzz-multi-driver-beta-two', %w[--target beta_two --seed 9]]],
                 runs.map { |run| [run.name, run.arguments] }
    assert_refused({ 'missing_table.rb' => "# erx-gate: fuzz timed targets=FuzzDriversTestNoSuch::TABLE\n" },
                   'names FuzzDriversTestNoSuch::TABLE, which it does not define')
  end

  # The seeded fault: a driver whose declaration is dropped stops the plan.
  def test_a_driver_without_its_line_stops_the_plan
    assert_refused({ 'erx_new.rb' => "# frozen_string_literal: true\n" },
                   'tools/fuzz/erx_new.rb has 0 `# erx-gate: fuzz` lines')
    assert_refused({ 'erx_new.rb' => "# erx-gate: fuzz fixed\n# erx-gate: fuzz fixed\n" },
                   'has 2 `# erx-gate: fuzz` lines')
    assert_refused({ 'erx_new.rb' => "# erx-gate: fuzzy seeded deadline=9\n" }, 'has 0 `# erx-gate: fuzz` lines')
  end

  def test_malformed_declarations_are_refused
    {
      "# erx-gate: fuzz hourly\n" => 'declares kind "hourly"',
      "# erx-gate: fuzz\n" => 'declares kind nil',
      "# erx-gate: fuzz seeded\n" => 'a seeded driver takes deadline, targets, each at most once, and needs deadline',
      "# erx-gate: fuzz fixed deadline=10\n" => 'a fixed driver takes',
      "# erx-gate: fuzz seeded deadline=10 deadline=20\n" => 'each at most once',
      "# erx-gate: fuzz seeded deadline=0\n" => 'its value is malformed',
      "# erx-gate: fuzz seeded deadline=99999\n" => 'its value is malformed',
      "# erx-gate: fuzz timed targets=lower::case\n" => 'its value is malformed',
      "# erx-gate: fuzz seeded deadline\n" => 'not KEY=VALUE',
      "# erx-gate: fuzz timed budget=3\n" => 'a timed driver takes targets, each at most once, and needs nothing'
    }.each { |line, message| assert_refused({ 'bad.rb' => line }, message) }
  end

  # Every name reaches the runner as a command name, once.
  def test_names_the_runner_refuses_or_shares_stop_the_plan
    assert_refused({ 'Erx.V2.rb' => "# erx-gate: fuzz fixed\n" }, 'is not named in lower case')
    assert_refused({ 'dup.rb' => "# erx-gate: fuzz fixed\n", 'dup_fuzz.rb' => "# erx-gate: fuzz fixed\n" },
                   'two runs are each named fuzz-dup')
  end

  # A driver that cannot be loaded to read its table fails through the one route.
  def test_a_driver_that_fails_to_load_is_refused
    assert_refused({ 'broken.rb' => "# erx-gate: fuzz timed targets=FuzzDriversTestBroken::T\nraise \"boom\"\n" },
                   'cannot be loaded to read FuzzDriversTestBroken::T: RuntimeError: boom')
  end
end
