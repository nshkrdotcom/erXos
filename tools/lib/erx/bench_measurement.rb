# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'bench_record'
require_relative 'error'

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
      reason = refusal(value, workload: workload, iterations: iterations, samples: samples, flavour: flavour)
      raise Error, "benchmark measurement #{reason}" if reason
    end

    # The first reason a measurement is refused, or nil when it is acceptable.
    def refusal(value, workload:, iterations:, samples:, flavour:)
      return 'is not a JSON object' unless value.is_a?(Hash)

      asked = { 'workload' => workload, 'iterations' => iterations, 'samples' => samples,
                'emu_flavor' => flavour, 'schedulers' => 1 }
      wrong = asked.find { |field, want| !value[field].eql?(want) }
      return "field #{wrong.first} is not the requested #{wrong.last}" if wrong

      times = value['ns_per_operation']
      if !positive_integer?(value['operations'])
        'field operations is not a positive integer'
      elsif !(value['beam_md5'].is_a?(String) && MD5_HEX.match?(value['beam_md5']))
        'field beam_md5 is not a lowercase MD5 digest'
      elsif !(times.is_a?(Array) && times.size == samples)
        'field ns_per_operation is not one number per sample'
      elsif !times.all? { |time| time.is_a?(Numeric) && time.finite? && time.positive? }
        'field ns_per_operation holds a time that is not positive and finite'
      end
    end

    def positive_integer?(value) = value.is_a?(Integer) && value.positive?

    # The BENCH line a guest prints for one cell (docs/design-bench.md, "A benchmark"):
    # BENCH, a space, and one JSON object of at most 64 KiB in printable ASCII, in clock
    # ticks. Every field has a type and a bound, every unknown field is refused, and a
    # refusal names the field, never the line's text. The cell's benchmark and operation
    # names, and so its file name, are the declared ones the line is checked against.
    # A histogram needs no length bound of its own: its buckets are disjoint, each holds a
    # sample, and together they hold the cell's samples, at most what the profile asked.
    LINE_PREFIX = 'BENCH '
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
    # A reason: lowercase words, no control character, nothing a terminal interprets.
    REASON = /\A[a-z][a-z0-9 ,:_()-]{0,79}\z/
    REQUIRED = %w[benchmark operation conditions frequency_hz status samples histogram largest counts].freeze
    # The optional fields, and the profile each belongs to (nil: any profile).
    OPTIONAL = { 'reason' => nil, 'min' => nil, 'max' => nil, 'uncertainty' => nil, 'raw' => 'expensive',
                 'phases' => 'periodic', 'excess' => 'periodic' }.freeze
    CONDITIONS = %w[load placement parameters clock batch].freeze
    COUNTS = %w[lost early missed].freeze

    # The cell one BENCH line reports for benchmark, whose operations profiles maps to
    # the BenchRecord::Profile each ran at. Raises Erx::Error naming the first field that
    # is wrong; the line's text is never quoted.
    def cell(text, benchmark:, profiles:)
      fields = decode(text)
      need(fields['benchmark'] == benchmark, 'field benchmark is not the benchmark run')
      operation = profiles.keys.find { |name| name == fields['operation'] }
      need(operation, 'field operation is not one the benchmark declares')
      profile = profiles.fetch(operation)
      samples = fields['samples']
      need(count?(samples) && samples <= profile.samples, 'field samples is not a count the profile allows')
      status = fields['status']
      need(GUEST_STATUSES.include?(status), 'field status is not one a guest reports')
      need(status != 'measured' || samples == profile.samples, 'a measured cell lacks samples the profile asked for')
      reason = fields['reason']
      need(status == 'measured' ? reason.nil? : (reason.is_a?(String) && REASON.match?(reason)),
           'field reason is absent where it is needed, or not a plain reason')
      BenchRecord::Cell.new(benchmark: benchmark, operation: operation, conditions: conditions(fields['conditions']),
                            profile: profile, status: status, reason: reason, counts: counts(fields['counts']),
                            detail: detail(fields, profile: profile.name, samples: samples))
    end

    # The JSON object of a line: printable ASCII, bounded, no key twice, no key unknown,
    # and no field of a profile other than the cell's.
    def decode(text)
      need(text.is_a?(String) && text.b.start_with?(LINE_PREFIX), 'is not a BENCH line')
      body = text.b.delete_prefix(LINE_PREFIX)
      need(body.bytesize <= LINE_BYTES, 'is longer than 64 KiB')
      need(body.each_byte.all? { |byte| byte.between?(0x20, 0x7e) }, 'holds a byte that is not printable ASCII')
      # No field's character set needs an escape, and a decoded \u escape could be invalid
      # UTF-8; json also reads /* */ comments. Refusing both keeps the bytes the values.
      need(!body.match?(%r{[\\/]}), 'holds a backslash or a slash')
      fields = JSON.parse(body, max_nesting: 3, allow_nan: false, allow_duplicate_key: false,
                                create_additions: false)
      need(fields.is_a?(Hash), 'is not a JSON object')
      need((REQUIRED - fields.keys).empty?, 'lacks a required field')
      need((fields.keys - REQUIRED - OPTIONAL.keys).empty?, 'holds an unknown field')
      fields
    rescue JSON::ParserError, JSON::NestingError
      need(false, 'is not one JSON object nested at most three deep')
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
      need(fields.key?('min') == samples.positive? && fields.key?('max') == samples.positive?,
           'fields min and max are not given exactly when there are samples')
      range = samples.positive? ? extremes(fields, histogram) : nil
      largest(fields['largest'], range: range, samples: samples)
      raw(fields['raw'], range: range, samples: samples) if fields.key?('raw')
      phases(fields, samples: samples) if profile == 'periodic'
      need(!fields.key?('uncertainty') || tick?(fields['uncertainty']), 'field uncertainty is not a tick count')
      need(fields['frequency_hz'].is_a?(Integer) && FREQUENCY_HZ.cover?(fields['frequency_hz']),
           'field frequency_hz is not a frequency')
      fields.slice('frequency_hz', 'histogram', 'min', 'max', 'largest', 'raw', 'phases', 'excess', 'uncertainty')
    end

    def histogram(value, name)
      need(BenchRecord.histogram?(value) && value.all? { |bucket| bucket.all?(TICK) },
           "field #{name} is not ascending [low, last, count] buckets of ticks")
      value
    end

    # min and max, each inside the bucket that must hold it: the range of every sample.
    def extremes(fields, histogram)
      low, = histogram.first
      _, last, = histogram.last
      min, max = fields.values_at('min', 'max')
      need(min.is_a?(Integer) && max.is_a?(Integer) && min <= max, 'fields min and max are not ordered ticks')
      need(min.between?(low, histogram.first[1]) && max.between?(histogram.last[0], last),
           'fields min and max lie outside the histogram buckets that hold them')
      min..max
    end

    # The largest samples, [sequence, value] with value not increasing, the first the
    # maximum; at most sixteen, and no more than there are samples.
    def largest(value, range:, samples:)
      need(value.is_a?(Array) && value.size <= [LARGEST, samples].min &&
           value.all? { |entry| entry.is_a?(Array) && entry.size == 2 && entry.all?(Integer) },
           'field largest is not at most sixteen [sequence, value] pairs')
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

    def need(valid, reason)
      raise Error, "BENCH line #{reason}" unless valid
    end

    private_class_method :decode, :conditions, :tick?, :count?, :parameter?, :counts, :detail, :histogram, :extremes, :largest,
                         :raw, :phases, :need
  end
end
