# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'error'
require_relative 'json_input'

module Erx
  # What one measurement from erx_otp_bench:run/3 must say before it is believed, whether
  # stock OTP printed it or the guest did: the workload, sizes and emulator flavour that
  # were asked for, one scheduler, and one positive finite time per sample. The numbers in
  # a refusal are never echoed; a guest's text is untrusted and the reason is shown on a
  # terminal.
  module BenchMeasurement
    MD5_HEX = /\A[0-9a-f]{32}\z/

    module_function

    # Raises Erx::Error naming the first field that is wrong.
    def validate(value, workload:, iterations:, samples:, flavour:)
      measured(value.is_a?(Hash), 'is not a JSON object')
      asked = { 'workload' => workload, 'iterations' => iterations, 'samples' => samples,
                'emu_flavor' => flavour, 'schedulers' => 1 }
      asked.each { |field, want| measured(value[field].eql?(want), "field #{field} is not the requested #{want}") }
      measured(positive_integer?(value['operations']), 'field operations is not a positive integer')
      measured(value['beam_md5'].is_a?(String) && MD5_HEX.match?(value['beam_md5']),
               'field beam_md5 is not a lowercase MD5 digest')
      times = value['ns_per_operation']
      measured(times.is_a?(Array) && times.size == samples, 'field ns_per_operation is not one number per sample')
      measured(times.all? { |time| time.is_a?(Numeric) && time.finite? && time.positive? },
               'field ns_per_operation holds a time that is not positive and finite')
    end

    def measured(valid, reason)
      raise Error, "benchmark measurement #{reason}" unless valid
    end

    def positive_integer?(value) = value.is_a?(Integer) && value.positive?

    # The BENCH line a guest prints for one cell (docs/design-bench.md, "A benchmark"):
    # BENCH, a space, and one JSON object of at most 64 KiB in printable ASCII, in clock
    # ticks. Every field has a type and a bound, every unknown field is refused, and a
    # refusal names the field, never the line's text. The cell's benchmark and operation
    # names, and so its file name, are the declared ones the line is checked against.
    # A histogram needs no length bound of its own: its buckets are disjoint, each holds a
    # sample, and together they hold the cell's samples, at most what the profile asked.
    LINE_BYTES = 64 << 10
    TICK = (0..((1 << 64) - 1))
    COUNT = (0..1_000_000_000)
    FREQUENCY_HZ = (1..10_000_000_000)
    LARGEST = 16
    RAW = 1000
    PHASES = 16
    # What a guest may report; the host alone decides timed_out, rejected and not_run.
    GUEST_STATUSES = %w[measured partial unsupported failed].freeze
    GUEST_CLOCKS = %w[counter virtual].freeze
    REQUIRED = %w[benchmark operation conditions frequency_hz status samples histogram largest counts].freeze
    # The optional fields, and the profile each belongs to (nil: any profile).
    OPTIONAL = { 'reason' => nil, 'min' => nil, 'max' => nil, 'uncertainty' => nil, 'raw' => 'expensive',
                 'phases' => 'periodic', 'excess' => 'periodic' }.freeze
    CONDITIONS = %w[load placement parameters clock batch].freeze
    COUNTS = %w[lost early missed].freeze
    # The CLOCK line: one per boot, the guest's calibration (docs/design-bench.md, "A
    # benchmark", "The one clock"), which becomes the record's clock group.
    CLOCK_FIELDS = %w[clock frequency_hz increment read_cost wait_rounding cycles_per_tick pairs].freeze
    # Cycles per counter tick, the CPU's frequency over the counter's, is at most this.
    MAX_CYCLES_PER_TICK = 1000
    PAIR_FIELDS = %w[cpus before after].freeze
    PAIRS = 64
    CPU = (0..255)
    OFFSET = (-(1 << 63)..((1 << 63) - 1))

    # The cell one BENCH line reports for benchmark, whose operations profiles maps to
    # the BenchRecord::Profile each ran at. Raises Erx::Error naming the first field that
    # is wrong; the line's text is never quoted.
    def cell(text, benchmark:, profiles:) = refusing('BENCH') { bench_cell(text, benchmark: benchmark, profiles: profiles) }

    # The clock group one CLOCK line reports, frozen through. Each pair of CPUs, lower
    # first, a cell was stamped across has its offset interval before the cells and after
    # them, each [lowest, highest] in ticks of the second CPU's counter less the first's,
    # or null where the stamps contradicted each other. cycles_per_tick is a number, or
    # unknown where the CPU's cycle counter could not be read. Raises Erx::Error naming
    # the first wrong field.
    def clock(text) = refusing('CLOCK') { clock_group(text) }

    # What a boot asked of its guest (docs/design-bench.md, "The gates"): the declared
    # benchmark (a BenchSuite::Benchmark), its landing cells in that boot, the
    # BenchRecord::Profile each operation ran at, the clock the environment reads, and the
    # CPU pairs, lower first, that its two-CPU cells span.
    Asked = Data.define(:benchmark, :cells, :profiles, :clock, :pairs)

    # A boot's clock group and cells from the guest lines it printed, each a BENCH or a
    # CLOCK line (docs/design-bench.md, "A benchmark"), held to what the boot asked. A
    # BENCH line reports one of asked's cells, once, on its clock; a handshake's in batch
    # 1. The CLOCK line reads asked's clock and calibrates exactly its pairs. Without
    # exactly one such CLOCK line the boot has no calibration and its cells are rejected,
    # and so is a cell whose frequency is not the CLOCK line's. A failed cell stays failed
    # in both only when its failure does not depend on the clock (a lost wake, a wrong
    # status), and keeps only its status, reason and counts. A calibrated handshake carries
    # the clock's read cost and increment. An asked cell no line reported is not_run, or
    # rejected when a BENCH line was refused. Each refused line's reason is returned in
    # refused, never its text.
    def boot(lines, asked)
      clocks, benches = lines.partition { |text| text.is_a?(String) && text.b.start_with?('CLOCK ') }
      seen = {}
      answers = benches.map do |text|
        judged { held(cell(text, benchmark: asked.benchmark.name, profiles: asked.profiles), asked, seen) }
      end
      cells, refused = answers.partition { |answer| answer.is_a?(BenchRecord::Cell) }
      calibration = clocks.size == 1 ? judged { calibrated(clocks.first, asked) } : 'the boot has not exactly one CLOCK line'
      group = calibration unless calibration.is_a?(String)
      unreported = (asked.cells - seen.values).map { |declared| unreported(declared, asked, refused: !refused.empty?) }
      { clock: group, cells: cells.map { |found| verdict(found, group, asked) } + unreported,
        refused: refused + [calibration].grep(String) }
    end

    # The block's answer, or the reason it was refused.
    def judged
      yield
    rescue Error => e
      e.message
    end

    # cell, once it is shown to be one asked for; seen maps each asked cell reported to its
    # line's cell.
    def held(cell, asked, seen)
      conditions = cell.conditions
      declared = asked.cells.find do |wanted|
        [wanted.operation, wanted.load, wanted.placement, wanted.parameters] ==
          [cell.operation, conditions.load, conditions.placement, conditions.parameters]
      end
      refusing('BENCH') do
        need(declared, 'reports a cell the boot did not ask for')
        need(conditions.clock == asked.clock, 'reads a clock that is not the one the boot reads')
        need(!handshake?(cell, asked) || conditions.batch == 1, 'times a handshake in batches, not in batch 1')
        need(declared.cpus == 1 || cell.status == 'unsupported' || !asked.pairs.empty?,
             'times across two CPUs the boot did not calibrate')
        need(!seen.key?(cell.key), 'reports a cell twice')
      end
      seen[cell.key] = declared
      cell
    end

    # The clock group of the boot's CLOCK line, on the clock asked and over its pairs.
    def calibrated(text, asked)
      group = clock(text)
      refusing('CLOCK') do
        need(group.fetch('clock') == asked.clock, 'field clock is not the clock the boot reads')
        need(group.fetch('pairs').map { |pair| pair.fetch('cpus') }.sort == asked.pairs.sort,
             'field pairs does not calibrate the pairs the boot asked for')
      end
      group
    end

    # An asked cell no line reported: not_run, or rejected where a line it may have been was refused.
    def unreported(declared, asked, refused:)
      status, reason = refused ? ['rejected', 'a line of the boot was refused'] : ['not_run', 'the guest printed no line for it']
      BenchRecord::Cell.new(benchmark: asked.benchmark.name, operation: declared.operation,
                            conditions: BenchRecord::Conditions.new(load: declared.load, placement: declared.placement,
                                                                    parameters: declared.parameters, clock: asked.clock,
                                                                    batch: 1),
                            profile: asked.profiles.fetch(declared.operation), status: status, reason: reason,
                            counts: COUNTS.to_h { |name| [name, 0] }, detail: {})
    end

    def handshake?(cell, asked) = asked.benchmark.operations.fetch(cell.operation).handshake

    def verdict(cell, group, asked)
      unjudged = if group.nil? then 'no valid CLOCK line in the boot'
                 elsif cell.detail['frequency_hz'] != group.fetch('frequency_hz')
                   'frequency differs from the CLOCK line'
                 end
      return quantized(cell, group, asked) if unjudged.nil?
      return stripped(cell, status: 'failed', reason: cell.reason) if clock_free_failure?(cell)

      stripped(cell, status: 'rejected', reason: unjudged)
    end

    # A handshake's cell is timed one operation per sample, however short (docs/design-bench.md,
    # "The one clock"), so it carries the clock's read cost and increment beside its samples.
    def quantized(cell, group, asked)
      return cell unless handshake?(cell, asked)

      BenchRecord::Cell.new(**cell.to_h, detail: cell.detail.merge(group.slice('read_cost', 'increment')))
    end

    # A failure the clock did not judge: a lost wake, or a wrong result the counts do not
    # show. An early return is judged by the clock, so a cell failed only by early returns
    # fails nothing without one.
    def clock_free_failure?(cell)
      cell.status == 'failed' && (cell.counts.fetch('lost').positive? || cell.counts.fetch('early').zero?)
    end

    # The cell with no tick statistics, which a boot without a calibration cannot vouch for.
    def stripped(cell, status:, reason:) = BenchRecord::Cell.new(**cell.to_h, status: status, reason: reason, detail: {})

    # A line's refusals, from its own checks and from the record part it builds, each
    # say once which kind of line was refused.
    def refusing(kind)
      yield
    rescue BenchRecord::Invalid => e
      raise Error, "#{kind} line #{e.reason}"
    end

    def bench_cell(text, benchmark:, profiles:)
      fields = decode(text, kind: 'BENCH', required: REQUIRED, known: REQUIRED + OPTIONAL.keys)
      need(fields['benchmark'] == benchmark, 'field benchmark is not the benchmark run')
      operation = profiles.keys.find { |name| name == fields['operation'] }
      need(operation, 'field operation is not one the benchmark declares')
      profile = profiles.fetch(operation)
      samples = fields['samples']
      need(count?(samples) && samples <= profile.samples, 'field samples is not a count the profile allows')
      status = fields['status']
      need(GUEST_STATUSES.include?(status), 'field status is not one a guest reports')
      need(frequency?(fields['frequency_hz']), 'field frequency_hz is not a frequency')
      # The cell itself holds a measured cell to every sample, the reason to its
      # character set and the extremes to their buckets, whether read from a line or a file.
      BenchRecord::Cell.new(benchmark: benchmark, operation: operation, conditions: conditions(fields['conditions']),
                            profile: profile, status: status, reason: fields['reason'], counts: counts(fields['counts']),
                            detail: detail(fields, profile: profile.name, samples: samples))
    end

    def clock_group(text)
      fields = decode(text, kind: 'CLOCK', required: CLOCK_FIELDS, known: CLOCK_FIELDS)
      need(GUEST_CLOCKS.include?(fields['clock']), 'field clock is not a guest clock')
      need(frequency?(fields['frequency_hz']), 'field frequency_hz is not a frequency')
      need(tick?(fields['increment']) && fields['increment'].positive?, 'field increment is not a positive tick count')
      %w[read_cost wait_rounding].each { |name| need(tick?(fields[name]), "field #{name} is not a tick count") }
      cycles = fields['cycles_per_tick']
      need(cycles == 'unknown' || (cycles.is_a?(Numeric) && cycles.finite? && cycles.positive? &&
                                   cycles <= MAX_CYCLES_PER_TICK),
           'field cycles_per_tick is not a positive number or unknown')
      pairs(fields['pairs'])
      BenchRecord.frozen(fields)
    end

    # The JSON object of a kind's line: printable ASCII, bounded, no key twice, every
    # required key and no unknown one, frozen.
    def decode(text, kind:, required:, known:)
      prefix = "#{kind} "
      need(text.is_a?(String) && text.b.start_with?(prefix), "does not begin with #{kind} and a space")
      body = text.b.delete_prefix(prefix)
      need(body.bytesize <= LINE_BYTES, 'is longer than 64 KiB')
      need(body.each_byte.all? { |byte| byte.between?(0x20, 0x7e) }, 'holds a byte that is not printable ASCII')
      # No field's character set needs an escape, and a decoded \u escape could be invalid
      # UTF-8; json also reads /* */ comments. Refusing both keeps the bytes the values.
      need(!body.match?(%r{[\\/]}), 'holds a backslash or a slash')
      fields = parsed(body, kind: kind)
      need(fields.is_a?(Hash), 'is not a JSON object')
      need((required - fields.keys).empty?, 'lacks a required field')
      need((fields.keys - known).empty?, 'holds an unknown field')
      fields
    end

    # JsonInput's refusals name the line's kind, never its text.
    def parsed(body, kind:)
      JsonInput.parse(body, max_bytes: LINE_BYTES, max_nesting: 4, label: 'it')
    rescue Error => e
      need(false, "is not one JSON object nested at most four deep (#{e.message})")
    end

    def conditions(value)
      need(value.is_a?(Hash) && value.keys.sort == CONDITIONS.sort, 'field conditions does not hold its members')
      parameters = value['parameters']
      need(parameters.is_a?(Hash) && parameters.size <= 8 &&
           parameters.all? { |name, given| BenchRecord::NAME.match?(name) && parameter?(given) },
           'field conditions.parameters is not names of counts or names')
      need(GUEST_CLOCKS.include?(value['clock']), 'field conditions.clock is not a guest clock')
      need(value['batch'].is_a?(Integer) && count?(value['batch']), 'field conditions.batch is not a count')
      need(%w[load placement].all? { |name| value[name].is_a?(String) && BenchRecord::NAME.match?(value[name]) },
           'field conditions.load or conditions.placement is not a plain name')
      BenchRecord::Conditions.new(**value.transform_keys(&:to_sym))
    end

    # An integer in range: JSON's 5.0 is a Float, which Range#cover? would let through.
    def tick?(value) = value.is_a?(Integer) && TICK.cover?(value)
    def count?(value) = value.is_a?(Integer) && COUNT.cover?(value)

    def frequency?(value) = value.is_a?(Integer) && FREQUENCY_HZ.cover?(value)

    def pairs(value)
      need(value.is_a?(Array) && value.size <= PAIRS &&
           value.all? { |pair| pair.is_a?(Hash) && pair.keys.sort == PAIR_FIELDS.sort },
           'field pairs is not at most 64 objects of cpus, before and after')
      need(value.all? { |pair| cpu_pair?(pair['cpus']) }, 'field pairs holds cpus that are not two CPUs, lower first')
      need(value.map { |pair| pair['cpus'] }.uniq.size == value.size, 'field pairs names one pair twice')
      need(value.all? { |pair| [pair['before'], pair['after']].all? { |interval| interval?(interval) } },
           'field pairs holds an interval that is neither null nor a lowest and highest offset')
    end

    def cpu_pair?(value) = ends?(value, CPU) && value.first < value.last
    def interval?(value) = value.nil? || (ends?(value, OFFSET) && value.first <= value.last)
    def ends?(value, range) = value.is_a?(Array) && value.size == 2 && value.all? { |end_| end_.is_a?(Integer) && range.cover?(end_) }

    def parameter?(value) = tick?(value) ||
                            (value.is_a?(String) && BenchRecord::NAME.match?(value))

    def counts(value)
      need(value.is_a?(Hash) && value.keys.sort == COUNTS.sort && value.values.all? { |count| count?(count) },
           'field counts is not lost, early and missed counts')
      value
    end

    # The operation file's detail: the histogram, the extremes, the largest samples and
    # whatever the profile adds, each checked against the others.
    def detail(fields, profile:, samples:)
      wrong = OPTIONAL.find { |name, owner| fields.key?(name) && owner && owner != profile }
      need(wrong.nil?, 'holds a field of another profile')
      histogram = histogram(fields['histogram'], 'histogram')
      need(histogram.sum { |_, _, count| count } == samples, 'field histogram does not hold every sample')
      range = BenchRecord.extremes(fields)
      largest(fields['largest'], range: range, samples: samples)
      need(profile != 'expensive' || fields.key?('raw'), 'field raw is absent from an expensive cell')
      raw(fields['raw'], range: range, samples: samples) if fields.key?('raw')
      phases(fields, samples: samples) if profile == 'periodic'
      need(!fields.key?('uncertainty') || tick?(fields['uncertainty']), 'field uncertainty is not a tick count')
      fields.slice('frequency_hz', 'histogram', 'min', 'max', 'largest', 'raw', 'phases', 'excess', 'uncertainty')
    end

    def histogram(value, name)
      need(BenchRecord.histogram?(value) && value.all? { |bucket| bucket.all?(TICK) },
           "field #{name} is not ascending [low, last, count] buckets of ticks")
      value
    end

    # The largest samples, [sequence, value] with value not increasing, the first the
    # maximum: sixteen, or every sample where there are fewer.
    def largest(value, range:, samples:)
      need(value.is_a?(Array) && value.size == [LARGEST, samples].min &&
           value.all? { |entry| entry.is_a?(Array) && entry.size == 2 && entry.all?(Integer) },
           'field largest is not the sixteen largest [sequence, value] pairs, or every sample')
      need(value.all? { |sequence, sample| (0...samples).cover?(sequence) && range.cover?(sample) } &&
           value.each_cons(2).all? { |(_, high), (_, low)| high >= low } &&
           (value.empty? || value.first.last == range.last),
           'field largest is not samples in descending order from the maximum')
      need(value.map(&:first).uniq.size == value.size, 'field largest names one sample twice')
    end

    def raw(value, range:, samples:)
      need(value.is_a?(Array) && value.size == samples && samples <= RAW && value.all?(Integer) &&
           value.all? { |sample| range.cover?(sample) }, 'field raw is not every sample, at most a thousand')
    end

    # A periodic cell's sixteen sweep phases, [minimum lateness, returns] each, and the
    # histogram of every return's excess above its phase's minimum.
    def phases(fields, samples:)
      phases = fields['phases']
      need(phases.is_a?(Array) && phases.size == PHASES &&
           phases.all? { |entry| entry.is_a?(Array) && entry.size == 2 && entry.all?(Integer) } &&
           phases.all? { |minimum, returns| tick?(minimum) && count?(returns) } &&
           phases.sum(&:last) == samples, 'field phases is not sixteen [minimum, returns] phases of every sample')
      excess = histogram(fields['excess'], 'excess')
      need(excess.sum { |_, _, count| count } == samples, 'field excess does not hold every sample')
    end

    def need(valid, reason) = valid || raise(BenchRecord::Invalid, reason)

    private_class_method :measured, :judged, :verdict, :clock_free_failure?, :stripped, :refusing, :bench_cell,
                         :clock_group, :decode, :held, :calibrated, :unreported, :handshake?, :quantized,
                         :parsed, :conditions, :tick?, :count?, :frequency?, :pairs, :cpu_pair?, :interval?, :ends?,
                         :parameter?, :counts, :detail, :histogram, :largest, :raw, :phases, :need
  end
end
