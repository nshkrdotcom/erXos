# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The Ruby fuzz drivers `tools/erx check-fuzz` runs: every *.rb file in
  # tools/fuzz and test/fuzz except the native targets' KIND_target.rb
  # declarations, which PackFuzz owns. Each file says how it is run in one
  # line of its own, so adding a driver is adding its file:
  #
  #   # erx-gate: fuzz seeded deadline=SECONDS [targets=CONSTANT]
  #       ruby FILE [--target NAME] --seed SEED, under its own deadline: a
  #       driver that bounds its own work and takes the gate's seed
  #   # erx-gate: fuzz timed [targets=CONSTANT]
  #       ruby FILE [--target NAME] --seconds BUDGET --seed SEED, under
  #       BUDGET + TIMED_SLACK seconds
  #   # erx-gate: fuzz fixed
  #       ruby FILE, under FIXED_DEADLINE seconds: a driver with its own
  #       iteration count and seed
  #   # erx-gate: fuzz helper
  #       not run from here: a library the drivers or tools/erx load
  #
  # targets= names the driver's own constant (a Hash whose keys, or an Array
  # whose elements, are its --target names); the file is loaded to read it,
  # so the targets have one list, and each target is one run. A file with
  # no such line, with two, or with a malformed one stops the plan instead
  # of shrinking it; test/host/fuzz_drivers_test.rb plans the real
  # directories, so make check stops on it too, long before the gate.
  module FuzzDrivers
    module_function

    DIRECTORIES = %w[tools/fuzz test/fuzz].freeze
    TIMED_SLACK = 30
    FIXED_DEADLINE = 180
    # The keys each kind takes, and those it must have.
    KINDS = {
      'seeded' => { allowed: %w[deadline targets], required: %w[deadline] },
      'timed' => { allowed: %w[targets], required: [] },
      'fixed' => { allowed: [], required: [] },
      'helper' => { allowed: [], required: [] }
    }.freeze
    DECLARATION = /\A# erx-gate: fuzz\b(?<rest>.*)\z/
    PAIR = /\A(?<key>[a-z]+)=(?<value>\S+)\z/
    # A deadline of at most 9999 seconds; a constant path such as Erx::X::TARGETS.
    VALUES = { 'deadline' => /\A[1-9][0-9]{0,3}\z/, 'targets' => /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/ }.freeze
    TARGET_NAME = /\A[a-z0-9_]+\z/
    # A driver's file name, which with its targets makes a command name the runner takes.
    FILE_NAME = /\A[a-z0-9_]+\.rb\z/

    # One file's declaration; targets is nil for a driver run once.
    Driver = Data.define(:path, :kind, :deadline, :targets)
    # One command of the plan: ruby, root/path, then arguments.
    Run = Data.define(:name, :path, :arguments, :deadline)

    # Every run of every driver under root, sorted by path, then in the
    # order of the driver's table; two runs never share a name.
    def runs(root:, seconds:, seed:, directories: DIRECTORIES)
      plan = drivers(root: root, directories: directories)
             .reject { |driver| driver.kind == 'helper' }
             .flat_map { |driver| driver_runs(driver, seconds: seconds, seed: seed) }
      shared = plan.map(&:name).tally.select { |_name, count| count > 1 }.keys
      raise Error, "fuzz drivers: two runs are each named #{shared.join(', ')}" unless shared.empty?

      plan
    end

    # Every declared file under root, helpers included, sorted by path.
    def drivers(root:, directories: DIRECTORIES)
      paths = directories.flat_map { |directory| Dir.glob("#{directory}/*.rb", base: root) }
                         .reject { |path| path.end_with?('_target.rb') }.sort
      raise Error, "fuzz drivers: no *.rb file in #{directories.join(' or ')}" if paths.empty?

      paths.map { |path| declaration(File.expand_path(root), path) }
    end

    def driver_runs(driver, seconds:, seed:)
      stem = File.basename(driver.path, '.rb').delete_suffix('_fuzz')
      (driver.targets || [nil]).map do |target|
        name = ['fuzz', stem, target].compact.join('-').tr('_', '-')
        selector = target ? ['--target', target] : []
        case driver.kind
        in 'seeded' then Run.new(name, driver.path, [*selector, '--seed', seed.to_s], driver.deadline)
        in 'timed'
          Run.new(name, driver.path, [*selector, '--seconds', seconds.to_s, '--seed', seed.to_s], seconds + TIMED_SLACK)
        in 'fixed' then Run.new(name, driver.path, [], FIXED_DEADLINE)
        end
      end
    end

    def declaration(root, path)
      refuse(path, 'is not named in lower case, digits and underscores') unless FILE_NAME.match?(File.basename(path))
      lines = File.foreach(File.join(root, path), chomp: true).filter_map { |line| DECLARATION.match(line) }
      unless lines.size == 1
        refuse(path, "has #{lines.size} `# erx-gate: fuzz` lines; it needs one saying how check-fuzz runs it")
      end
      kind, *pairs = lines.first[:rest].split
      rule = KINDS.fetch(kind) { refuse(path, "declares kind #{kind.inspect}, not one of #{KINDS.keys.join(', ')}") }
      fields = pairs.to_h { |pair| field(path, pair) }
      unless fields.size == pairs.size && (fields.keys - rule.fetch(:allowed)).empty? &&
             (rule.fetch(:required) - fields.keys).empty?
        refuse(path, "declares #{pairs.join(' ').inspect}; a #{kind} driver takes #{listed(rule.fetch(:allowed))}, " \
                     "each at most once, and needs #{listed(rule.fetch(:required))}")
      end
      Driver.new(path: path, kind: kind, deadline: fields['deadline']&.to_i,
                 targets: fields['targets']&.then { |constant| target_names(root, path, constant) })
    end

    def field(path, pair)
      key, value = PAIR.match(pair)&.captures
      refuse(path, "declares #{pair.inspect}, not KEY=VALUE") unless key
      pattern = VALUES[key]
      refuse(path, "declares #{pair.inspect}; its value is malformed") if pattern && !pattern.match?(value)
      [key, value]
    end

    def listed(keys) = keys.empty? ? 'nothing' : keys.join(', ')

    # Loads the driver, whose main program runs only as $PROGRAM_NAME, and
    # reads its target names from the constant it named.
    def target_names(root, path, constant)
      begin
        require File.join(root, path)
      rescue ScriptError, StandardError => error
        refuse(path, "cannot be loaded to read #{constant}: #{error.class}: #{error.message.lines.first&.chomp}")
      end
      refuse(path, "names #{constant}, which it does not define") unless Object.const_defined?(constant)
      table = Object.const_get(constant)
      names = table.is_a?(Hash) ? table.keys : table
      unless names.is_a?(Array) && !names.empty? && names.all? { |name| name.is_a?(String) && TARGET_NAME.match?(name) }
        refuse(path, "names #{constant}, which is not a non-empty list of plain target names")
      end
      names.dup.freeze
    end

    def refuse(path, problem) = raise(Error, "fuzz drivers: #{path} #{problem}")

    private_class_method :driver_runs, :declaration, :field, :listed, :target_names, :refuse
  end
end
