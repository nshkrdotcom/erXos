# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'git_environment'
require_relative 'source_revision'

module Erx
  # One benchmark run's record and its one writer (docs/design-bench.md, "The record").
  # A record separates where the run happened (its Environment, whose name is derived and
  # names the directory) from what ran (its Subject), and holds one Cell per operation
  # under one set of conditions. The writer puts it under
  # <history>/bench/<environment>/<run>/ and refuses any destination that is not a
  # separate git repository outside every worktree of the erXos repository, or that a
  # symbolic link would carry elsewhere. Every file name is derived from validated
  # declaration names and the run's own facts, never from a guest's line.
  module BenchRecord
    # The format a record is written in; a record of any other is refused, never read.
    FORMAT = 1
    STATUSES = %w[measured partial timed_out unsupported failed rejected not_run].freeze
    CLOCKS = %w[counter host analyser virtual].freeze
    PROFILES = %w[fast expensive periodic sustained].freeze
    SYSTEMS = %w[erxos l4re freebsd linux].freeze
    # A benchmark, operation, load cell or placement name, as a declaration gives it.
    NAME = /\A[a-z][a-z0-9-]{0,31}\z/
    # A host's hardware model (sysctl hw.model on macOS): no path separator, no space.
    MODEL = /\A[A-Za-z0-9][A-Za-z0-9.,_-]{0,63}\z/
    REVISION = /\A(?:\h{40}|\h{64})\z/
    STARTED_BY = /\A(?:landing|milestone|manual|gate [A-Z][A-Z0-9]{0,7})\z/
    FILE_BYTES = 1 << 20
    LOG_BYTES = 64 << 20
    MANIFEST = 'run.json'
    # The statuses whose cell has no summary (docs/design-bench.md, "The record").
    NO_SUMMARY = %w[timed_out unsupported rejected not_run].freeze
    BOOT_LOGS = %i[serial qemu].freeze
    KINDS = %w[qemu-hvf qemu-tcg qemu-det pi4 host].freeze

    # The percentiles a summary reports, exact so that ceil(p * n) has no rounding error.
    P50 = 1 / 2r
    P99 = 99 / 100r
    P999 = 999 / 1000r
    PERCENTILES = { 'p50' => P50, 'p99' => P99, 'p999' => P999 }.freeze
    # A percentile is reported only with at least this many samples above it.
    ABOVE = 10
    TOO_FEW = { 'unsupported' => 'too few samples' }.freeze

    # A condition that a value fails names the field, never the value.
    def self.check(valid, what)
      raise Error, "bench record: #{what}" unless valid
    end

    def self.plain_hash?(value) = value.is_a?(Hash) && value.keys.all?(String)

    # Where a run happened. kind is one of KINDS; the name is derived from the fields
    # each kind uses, and details (memory, QEMU version, firmware hashes) are recorded
    # beside it and do not name the directory.
    Environment = Data.define(:kind, :model, :cpus, :system, :details) do
      def initialize(kind:, model:, cpus:, system:, details:)
        BenchRecord.check(KINDS.include?(kind), 'environment kind is not one of the kinds')
        BenchRecord.check(model.nil? || (model.is_a?(String) && MODEL.match?(model)), 'machine model is not plain')
        BenchRecord.check(cpus.nil? || (cpus.is_a?(Integer) && cpus.between?(1, 1024)), 'CPU count is not positive')
        BenchRecord.check(system.nil? || SYSTEMS.include?(system), 'system is not one of the board systems')
        BenchRecord.check(BenchRecord.plain_hash?(details), 'environment details are not a map')
        super(kind: kind, model: model, cpus: cpus, system: system, details: details.freeze)
        name
      end

      # docs/design-bench.md, "Environments": the name carries no host name.
      def name
        case kind
        when 'qemu-hvf', 'qemu-tcg'
          BenchRecord.check(model && cpus, "#{kind} needs a machine model and a CPU count")
          "#{kind}-#{model}-#{cpus}cpu"
        when 'qemu-det' then 'qemu-det'
        when 'pi4'
          BenchRecord.check(system, 'a board environment needs its system')
          "pi4-4gb-#{system}"
        else
          BenchRecord.check(model, 'a host environment needs its machine model')
          "host-#{model}"
        end
      end

      # TCG and deterministic numbers are compared only with their own kind.
      def isolated? = %w[qemu-tcg qemu-det].include?(kind)
    end

    # What ran: the source revision, whether the tree was dirty, and the rest of the
    # subject (image and workload hashes, compiler, flags, manifest) as recorded facts.
    Subject = Data.define(:revision, :dirty, :details) do
      def initialize(revision:, dirty:, details:)
        BenchRecord.check(revision.is_a?(String) && REVISION.match?(revision), 'revision is not a lowercase hash')
        BenchRecord.check([true, false].include?(dirty), 'dirty is not a boolean')
        BenchRecord.check(BenchRecord.plain_hash?(details), 'subject details are not a map')
        super(revision: revision, dirty: dirty, details: details.freeze)
      end
    end

    # When and why the run happened. load is the host's load average before and after,
    # nil where it was not read; reused_from names the run a replayed boot came from.
    Run = Data.define(:date, :started_by, :load, :host_cpus, :reused_from) do
      def initialize(date:, started_by:, load:, host_cpus:, reused_from:)
        BenchRecord.check(date.is_a?(Time) && date.utc?, 'date is not a UTC time')
        BenchRecord.check(started_by.is_a?(String) && STARTED_BY.match?(started_by), 'started_by is not a known start')
        BenchRecord.check(load.nil? || (load.is_a?(Array) && load.size == 2 &&
                                        load.all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 }),
                          'load is not a before and after pair')
        BenchRecord.check(host_cpus.nil? || (host_cpus.is_a?(Integer) && host_cpus.positive?),
                          'host CPU count is not positive')
        BenchRecord.check(reused_from.nil? || reused_from.is_a?(String), 'reused_from is not a run path')
        super
      end

      def replayed? = !reused_from.nil?
    end

    # Everything that makes two cells of one operation the same cell.
    Conditions = Data.define(:load, :placement, :parameters, :clock, :batch) do
      def initialize(load:, placement:, parameters:, clock:, batch:)
        BenchRecord.check([load, placement].all? { |name| name.is_a?(String) && NAME.match?(name) },
                          'load cell or placement is not a declaration name')
        BenchRecord.check(BenchRecord.plain_hash?(parameters), 'workload parameters are not a map')
        BenchRecord.check(CLOCKS.include?(clock), 'clock is not one of the clocks')
        BenchRecord.check(batch.is_a?(Integer) && batch.positive?, 'batch size is not positive')
        super(load: load, placement: placement, parameters: parameters.freeze, clock: clock, batch: batch)
      end
    end

    # How a cell was sampled: the profile and the sizes it ran at.
    Profile = Data.define(:name, :warmup, :samples, :runs) do
      def initialize(name:, warmup:, samples:, runs:)
        BenchRecord.check(PROFILES.include?(name), 'profile is not one of the profiles')
        BenchRecord.check(warmup.is_a?(Integer) && !warmup.negative?, 'warm-up count is negative')
        BenchRecord.check([samples, runs].all? { |count| count.is_a?(Integer) && count.positive? },
                          'sample or run count is not positive')
        super
      end
    end

    # One operation under one set of conditions. Every status but measured carries its
    # reason, so an unknown, partial, unsupported or timed-out result says why. summary
    # is what the profile allows (run.json); detail is the histogram, largest and raw
    # samples (the operation's file).
    Cell = Data.define(:benchmark, :operation, :conditions, :profile, :status, :reason, :summary, :counts,
                       :detail) do
      def initialize(benchmark:, operation:, conditions:, profile:, status:, reason:, summary:, counts:, detail:)
        BenchRecord.check([benchmark, operation].all? { |name| name.is_a?(String) && NAME.match?(name) },
                          'benchmark or operation is not a declaration name')
        BenchRecord.check(conditions.is_a?(Conditions) && profile.is_a?(Profile), 'cell conditions are not typed')
        BenchRecord.check(STATUSES.include?(status), 'status is not one of the cell statuses')
        BenchRecord.check(status == 'measured' ? reason.nil? : (reason.is_a?(String) && !reason.empty?),
                          'a cell that is not measured needs its reason')
        BenchRecord.check(counts.is_a?(Hash) && counts.keys.sort == %w[early lost missed] &&
                          counts.values.all? { |count| count.is_a?(Integer) && !count.negative? },
                          'counts are not lost, early and missed')
        BenchRecord.check(BenchRecord.plain_hash?(summary) && BenchRecord.plain_hash?(detail),
                          'summary or detail is not a map')
        BenchRecord.check(status != 'measured' || (counts['lost'].zero? && counts['early'].zero?),
                          'a cell with a lost wake or an early return is failed, not measured')
        BenchRecord.check(!NO_SUMMARY.include?(status) || summary.empty?, "a #{status} cell has no summary")
        super(benchmark: benchmark, operation: operation, conditions: conditions, profile: profile, status: status,
              reason: reason, summary: summary.freeze, counts: counts.freeze, detail: detail.freeze)
      end

      def key = [benchmark, operation, conditions]
      def file = "#{benchmark}/#{operation}.json"
    end

    Record = Data.define(:environment, :subject, :run, :clock, :cells) do
      def initialize(environment:, subject:, run:, clock:, cells:)
        BenchRecord.check(environment.is_a?(Environment) && subject.is_a?(Subject) && run.is_a?(Run),
                          'record parts are not typed')
        BenchRecord.check(BenchRecord.plain_hash?(clock), 'clock calibration is not a map')
        BenchRecord.check(cells.is_a?(Array) && !cells.empty? && cells.all?(Cell), 'record holds no cells')
        BenchRecord.check(cells.map(&:key).uniq.size == cells.size, 'record holds one cell twice')
        super(environment: environment, subject: subject, run: run, clock: clock.freeze, cells: cells.freeze)
      end

      # The run directory's name: UTC time, the revision's first twelve hex digits, and
      # -dirty when the tree was.
      def name = "#{run.date.strftime('%Y%m%dT%H%M%SZ')}-#{subject.revision[0, 12]}#{subject.dirty ? '-dirty' : ''}"
    end

    module_function

    # Percentile p of a histogram of [low, last, count] buckets in ascending order, each
    # holding the values from low to last, both included (test/guest/bench/bench_hist.h):
    # the last value of the bucket holding the sample of rank ceil(p * n), with that
    # bucket's width, or TOO_FEW when fewer than ABOVE samples lie above that rank.
    def percentile(histogram, p)
      count = histogram.sum { |_, _, samples| samples }
      rank = (p * count).ceil
      return TOO_FEW unless count - rank >= ABOVE

      seen = 0
      low, last, = histogram.find { |_, _, samples| (seen += samples) >= rank }
      { 'value' => last, 'bucket' => last - low + 1 }
    end

    def percentiles(histogram) = PERCENTILES.transform_values { |p| percentile(histogram, p) }

    # Writes record under history and returns the run directory's real path. boots is one
    # { serial:, qemu: } map of log paths per boot, copied as boot-<n>.serial.log and
    # boot-<n>.qemu.log. Everything is serialized and bounded before the directory is made,
    # and run.json is written last, by rename, so a run is complete once it exists.
    def write(record, history:, erxos_root:, boots: [])
      files = serialized(record).merge(boot_logs(boots))
      oversized = files.find { |name, bytes| bytes.bytesize > (name.end_with?('.log') ? LOG_BYTES : FILE_BYTES) }
      check(oversized.nil?, "#{oversized&.first} exceeds its size bound")
      destination = Destination.new(history: history, erxos_root: erxos_root)
      run = destination.make_run_directory(['bench', record.environment.name, record.name])
      manifest = files.delete(MANIFEST)
      files.each { |name, bytes| create(run, name, bytes) }
      create(run, "#{MANIFEST}.partial", manifest)
      File.rename(File.join(run, "#{MANIFEST}.partial"), File.join(run, MANIFEST))
      run
    end

    # The record in the run directory run, refused whole if any file is missing, too
    # large, of another format or not a record.
    def read(run)
      manifest = parse(File.join(run, MANIFEST))
      details = manifest.fetch('cells').map { |cell| cell.fetch('file') }.uniq.to_h do |file|
        check(file.is_a?(String) && %r{\A[a-z][a-z0-9-]*/[a-z][a-z0-9-]*\.json\z}.match?(file), 'cell file is not derived')
        [file, parse(File.join(run, file)).fetch('cells')]
      end
      from_h(manifest, details)
    rescue KeyError, TypeError, NoMethodError, ArgumentError => error
      raise Error, "bench record #{run}: not a record (#{error.class})"
    end

    def parse(path)
      value = JSON.parse(BoundedFile.read(path, maximum: FILE_BYTES))
      check(value.is_a?(Hash) && value['format'] == FORMAT, "#{path} is not of format #{FORMAT}")
      value
    rescue JSON::ParserError
      raise Error, "bench record: #{path} does not parse"
    end

    def serialized(record)
      operations = record.cells.group_by(&:file).transform_values do |cells|
        JSON.pretty_generate('format' => FORMAT, 'benchmark' => cells.first.benchmark,
                             'operation' => cells.first.operation,
                             'cells' => cells.map { |cell| { 'conditions' => cell.conditions.to_h, 'detail' => cell.detail } })
      end
      { MANIFEST => JSON.pretty_generate(to_h(record)) }.merge(operations)
    end

    def boot_logs(boots)
      boots.each_with_index.flat_map do |logs, index|
        check(logs.keys.all? { |kind| BOOT_LOGS.include?(kind) }, 'a boot log is not serial or qemu')
        logs.map { |kind, path| ["boot-#{index + 1}.#{kind}.log", BoundedFile.read(path, maximum: LOG_BYTES)] }
      end.to_h
    end

    def create(run, name, bytes)
      directory = File.dirname(name)
      Dir.mkdir(File.join(run, directory)) unless directory == '.' || File.directory?(File.join(run, directory))
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      File.open(File.join(run, name), flags, 0o644) { |output| output.write(bytes) }
    rescue SystemCallError => error
      raise Error, "bench record: cannot write #{name}: #{error.class}"
    end

    def to_h(record)
      environment, subject, run = record.environment, record.subject, record.run
      { 'format' => FORMAT,
        'environment' => environment.to_h.transform_keys(&:to_s).merge('name' => environment.name),
        'subject' => subject.to_h.transform_keys(&:to_s),
        'run' => run.to_h.transform_keys(&:to_s).merge('date' => run.date.iso8601),
        'clock' => record.clock,
        'cells' => record.cells.map do |cell|
          cell.to_h.except(:detail).transform_keys(&:to_s)
              .merge('conditions' => cell.conditions.to_h.transform_keys(&:to_s),
                     'profile' => cell.profile.to_h.transform_keys(&:to_s), 'file' => cell.file)
        end }
    end

    def from_h(manifest, details)
      keyword = ->(hash, *drop) { hash.except(*drop).transform_keys(&:to_sym) }
      cells = manifest.fetch('cells').map do |cell|
        conditions = Conditions.new(**keyword.call(cell.fetch('conditions')))
        detail = details.fetch(cell.fetch('file')).find { |entry| entry.fetch('conditions') == cell.fetch('conditions') }
        check(detail, 'an operation file lacks a cell the manifest lists')
        Cell.new(**keyword.call(cell, 'conditions', 'profile', 'file'), conditions: conditions,
                                                                   profile: Profile.new(**keyword.call(cell.fetch('profile'))),
                                                                   detail: detail.fetch('detail'))
      end
      run = manifest.fetch('run')
      Record.new(environment: Environment.new(**keyword.call(manifest.fetch('environment'), 'name')),
                 subject: Subject.new(**keyword.call(manifest.fetch('subject'))),
                 run: Run.new(**keyword.call(run, 'date'), date: Time.iso8601(run.fetch('date')).utc),
                 clock: manifest.fetch('clock'), cells: cells)
    end

    private_class_method :parse, :serialized, :boot_logs, :create, :to_h, :from_h

    # The checks on where a record may be written (docs/design-bench.md, "Where records
    # are written"). The history root must exist, be the top of a git work tree whose
    # common git directory is not the erXos repository's, and lie by real path outside
    # every worktree of the erXos repository; the run directory is then made one
    # component at a time from the root, refusing any symbolic link, and its real path
    # must lie under the root's and outside every erXos worktree.
    class Destination
      def initialize(history:, erxos_root:)
        @root = real_path(history, 'history root')
        top = git(@root, 'rev-parse', '--show-toplevel')
        refuse("is not the top of a git work tree: #{@root}") unless top && real_path(top, 'work tree') == @root
        erxos_common = git(erxos_root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        refuse("cannot find the erXos repository at #{erxos_root}") unless erxos_common
        common = git(@root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        refuse("shares the erXos repository's common git directory: #{@root}") if
          real_path(common, 'common git directory') == real_path(erxos_common, 'common git directory')
        @worktrees = worktrees(erxos_root)
        outside_worktrees(@root)
      end

      # Makes the run directory under the root from components, the last exclusively,
      # and returns its real path.
      def make_run_directory(components)
        *parents, run = components
        parent = parents.reduce(@root) { |path, component| directory(File.join(path, component), exclusive: false) }
        path = directory(File.join(parent, run), exclusive: true)
        real = File.realpath(path)
        refuse("leaves the history root: #{path}") unless real.start_with?("#{@root}/")
        outside_worktrees(real)
      end

      private

      # path, made here when absent (and, when exclusive, only then), if it is a
      # directory and no symbolic link. Its parent is checked first, so nothing is made
      # under a refused prefix.
      def directory(path, exclusive:)
        parent = File.realpath(File.dirname(path))
        refuse("leaves the history root: #{path}") unless parent == @root || parent.start_with?("#{@root}/")
        outside_worktrees(parent)
        made = make_directory(path)
        refuse("run directory already exists: #{path}") if exclusive && !made
        stat = File.lstat(path)
        refuse("is a symbolic link: #{path}") if stat.symlink?
        refuse("is not a directory: #{path}") unless stat.directory?
        path
      end

      def make_directory(path)
        Dir.mkdir(path, 0o755)
        true
      rescue Errno::EEXIST
        false
      end

      def outside_worktrees(path)
        inside = @worktrees.find { |tree| path == tree || path.start_with?("#{tree}/") }
        refuse("lies inside the erXos worktree #{inside}: #{path}") if inside
        path
      end

      # Every worktree git lists for the erXos repository, the main one included, by
      # real path where it still exists.
      def worktrees(erxos_root)
        listing = git(erxos_root, 'worktree', 'list', '--porcelain', '-z', line: false)
        refuse("cannot list the erXos repository's worktrees at #{erxos_root}") unless listing
        listing.split("\0").filter_map { |field| field.delete_prefix('worktree ') if field.start_with?('worktree ') }
               .map { |tree| File.exist?(tree) ? File.realpath(tree) : File.expand_path(tree) }
      end

      def real_path(path, what)
        File.realpath(path)
      rescue SystemCallError
        refuse("#{what} does not exist: #{path}")
      end

      # git's output in directory, or nil when git refuses there.
      def git(directory, *arguments, line: true)
        output, _, status = Open3.capture3(GitEnvironment.isolated, *SourceRevision::GIT, '-C', directory, *arguments,
                                           stdin_data: '')
        return nil unless status.success?

        line ? output.chomp : output
      end

      def refuse(reason) = raise(Error, "bench record: history destination #{reason}")
    end
  end
end
