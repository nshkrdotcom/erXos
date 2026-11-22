# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/bumble'
require_relative '../fixtures/erlang_build'

# erXos's Bluetooth decoders against Bumble's (docs/design-bluetooth.md, "Fuzz targets"):
# one corpus through erx_att:decode/1, erx_smp:decode/1, erx_hci:event/2 with
# erx_hci:return/2, and erx_l2cap:signal/1 (test/erlang/erx_bt_bumble_decode.erl, on
# stock's emulator, ERX_ERL and ERX_ERLC) and through Bumble's ATT_PDU, SMP_Command,
# HCI_Event and L2CAP_Control_Frame from_bytes (test/bt/bumble_decode.py, in Erx::Bumble's
# environment, made from the fetched pins), each printing one canonical line per frame,
# as the driver's documentation defines it. A frame on which they differ must be listed
# in test/bt/differences.txt,
# as documented (erXos's answer is the specification's and Bumble's is not) or upstream
# (a Bumble bug), with erXos's line, which erXos must then give exactly; a listed frame on
# which they agree is stale and fails too.
class ErxBtBumbleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_bumble_decode.erl].freeze
  DRIVER = File.join(ROOT, 'test/bt/bumble_decode.py')
  DIFFERENCES = File.join(ROOT, 'test/bt/differences.txt')
  KINDS = %w[documented upstream].freeze
  DEADLINE = '300'
  ATT = 'erlang/apps/erx_bt/src/erx_att.erl'
  SMP = 'erlang/apps/erx_bt/src/erx_smp.erl'
  HCI = 'erlang/apps/erx_bt/src/erx_hci.erl'
  L2CAP = 'erlang/apps/erx_bt/src/erx_l2cap.erl'

  # count octets from first, step apart, wrapping at 0xff, in hex.
  def self.octets(first, count, step: 1) = Array.new(count) { |index| format('%02x', (first + index * step) & 0xff) }.join

  # One frame of each PDU the decoders read: for ATT and SMP written from Core 6.3 Vol 3
  # Part F, section 3.4 (the requests and commands a server receives) and Part H, sections
  # 3.5 and 3.6; for HCI each event erx_hci decodes (Vol 4 Part E, 7.7), its code and
  # parameters, and a Command Complete of each command whose return erx_hci reads, and a
  # failed one; for LE signaling each code of Bumble's CommandCode that LE signaling
  # carries, as erx_l2cap lists its responses (Part A, Table 4.2), with Bumble's layout,
  # and a longer frame than MTUsig, though the line does not show the reject's reason that
  # tells it apart. Within a frame no two fields the line shows are equal and no 16-bit
  # field reads the same in either byte order, so a field read from the wrong place or in
  # the wrong order shows.
  SAMPLES = {
    'att' => %w[
      021702
      0401000512
      060100fe120028aabb
      080100fe120328
      080100fe1200112233445566778899aabbccddeeff
      0a2301
      0c23014500
      100100fe120028
      100100fe1200112233445566778899aabbccddeeff
      122301c0ffee
      1623014500c0ffee
      1800
      1801
      522301c0ffee
      1e
    ],
    'smp' => [
      '0103000d10070b', '0201002d0f0506', "03#{octets(0x10, 16)}", "04#{octets(0x20, 16)}", '0505',
      "06#{octets(0x30, 16)}", '07a1b20102030405060708', "08#{octets(0x40, 16)}", '0901c1c2c3c4c5c6', '0b0d',
      "0c#{octets(0, 64, step: 7)}", "0d#{octets(0x50, 16)}", '0e04'
    ],
    'hci' => [
      '0e050110000d34120c5d007856', "0e01021000#{octets(0x80, 64)}", "0e01032000#{octets(0x31, 8)}",
      '0e01091000a1a2a3a4a5a6', '0e01022000fb000f', '0e01051000fd03400a000200', '0e011a20004002',
      '0e011b20004102', '0e01030c00', '0e010a2000', '0e0101100c', '0f0c020604', '0500410013', '0800420001',
      '30004300', '13024100030042000500', '3e010044000001a1a2a3a4a5a628000000c80005', "3e013e#{'00' * 17}",
      '3e0300450018000200c000', '3e054600b1b2b3b4b5b6b7b86b5a'
    ],
    'l2cap' => [
      '010702000000', '0608040040004100', '0709040040004100', '120a080006000c000000c800', '130b02000100',
      '140c0a0080004000f70017000a00', '150d0a004000f70017000a000000', '160e040040000500',
      '170f0a008000f70017000a004000', '18100a00f70017000a0000004000', '19110600f70017004000', '1a1202000000',
      "08141800#{octets(0x70, 24)}"
    ]
  }.freeze
  # Frames beside the samples' mutations: a reserved Execute Write flag, a UUID of
  # neither 2 nor 16 octets, a Find By Type Value with an empty value, and SMP's code
  # 0x0A, which Core 6.3 lists as previously used, with Signing Information's layout;
  # a Hardware Error event, and a Disconnection Complete whose handle has bits above
  # its 12 set; an Information Response, a BR/EDR code, on LE signaling, a code
  # Bumble has no class for, and a command's header cut short.
  EXTRA = {
    'att' => %w[1802 080100fe1200112233 060100fe120028], 'smp' => ["0a#{octets(0x60, 16)}"],
    'hci' => %w[102a 0500412013], 'l2cap' => %w[0b15040002000000 1b130000 0602]
  }.freeze
  # Every ATT opcode alone: which PDUs the server takes, refuses or ignores.
  SWEEP = { 'att-op' => Array.new(256) { |op| format('%02x', op) } }.freeze
  # An octet past each sample's end.
  PAST = '5a'

  # Each sample as written, cut by its last octet and with PAST appended, then EXTRA,
  # then SWEEP, as `CODEC HEX` lines.
  def self.corpus
    mutated = SAMPLES.flat_map do |codec, frames|
      variants = frames.flat_map { |frame| [frame, frame[0...-2], frame + PAST] }.reject(&:empty?)
      (variants + EXTRA.fetch(codec)).uniq.map { |frame| "#{codec} #{frame}" }
    end
    mutated + SWEEP.flat_map { |codec, frames| frames.map { |frame| "#{codec} #{frame}" } }
  end

  Row = Data.define(:frame, :bumble, :erxos) do
    def agree? = bumble == erxos
  end

  def self.compared = @compared ||= compare(replaced: {})

  # Bumble's lines for the corpus, which no seed changes, so they are read once.
  def self.bumble_lines
    @bumble_lines ||= Dir.mktmpdir('erx-bt-bumble') do |work|
      path = File.join(work, 'corpus.txt')
      File.write(path, corpus.join("\n") + "\n")
      bumble(path)
    end
  end

  # The corpus's rows, erXos's lines from its modules with replaced applied
  # (ErlangBuild.compile's replaced).
  def self.compare(replaced:)
    Dir.mktmpdir('erx-bt-bumble') do |work|
      frames = corpus
      path = File.join(work, 'corpus.txt')
      File.write(path, frames.join("\n") + "\n")
      bumble = bumble_lines
      erxos = erxos(path, work, replaced)
      unless [bumble.size, erxos.size] == [frames.size, frames.size]
        raise "#{frames.size} frames, but Bumble answered #{bumble.size} and erXos #{erxos.size}"
      end

      frames.zip(bumble, erxos).map { |frame, theirs, ours| Row.new(frame: frame, bumble: theirs, erxos: ours) }
    end
  end

  def self.bumble(corpus)
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    Erx::Bumble.use(root: ROOT, runner: runner) do |environment|
      output, errors, status = Open3.capture3('gtimeout', '-k', '10', DEADLINE, *environment.argv(DRIVER, corpus),
                                              stdin_data: '')
      raise "bumble_decode failed: #{status}: #{errors}" unless status.success?

      output.lines(chomp: true)
    end
  end

  def self.erxos(corpus, work, replaced)
    ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
    lines = File.join(work, 'erxos.txt')
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                     '-eval', 'erx_bt_bumble_decode:main(), halt().', '-extra', corpus, lines,
                                     stdin_data: '')
    raise "erx_bt_bumble_decode failed: #{output}" unless status.success? && File.file?(lines)

    File.read(lines).lines(chomp: true)
  end

  Entry = Data.define(:kind, :reason, :erxos)

  # differences.txt's frames: entries of `kind KIND`, one or more `reason TEXT` lines,
  # then `frame CODEC HEX ERXOS-LINE` lines, separated by blank lines; `#` starts a comment.
  def self.differences
    File.read(DIFFERENCES).split(/\n\s*\n/).map { |block| block.lines(chomp: true).reject { |line| line.start_with?('#') } }
        .reject(&:empty?).each_with_object({}) do |lines, entries|
      kind = lines.shift.delete_prefix('kind ')
      raise "differences.txt: kind #{kind.inspect} is not one of #{KINDS.join(', ')}" unless KINDS.include?(kind)

      reason = lines.take_while { |line| line.start_with?('reason ') }.map { |line| line.delete_prefix('reason ') }
      frames = lines.drop(reason.size)
      raise "differences.txt: an entry of kind #{kind} gives no reason or no frame" if reason.empty? || frames.empty?

      frames.each do |line|
        codec, hex, erxos = line.delete_prefix('frame ').split(' ', 3)
        frame = "#{codec} #{hex}"
        raise "differences.txt lists #{frame} twice" if entries.key?(frame)

        entries[frame] = Entry.new(kind: kind, reason: reason.join(' '), erxos: erxos)
      end
    end
  end

  # What the rows break of differences.txt: a difference it does not list, a listed
  # frame the corpus does not hold or on which the sides agree, and a listed frame
  # whose erXos line is not the one listed.
  def self.failures(rows, listed)
    by_frame = rows.to_h { |row| [row.frame, row] }
    unlisted = rows.reject { |row| row.agree? || listed.key?(row.frame) }.map do |row|
      "#{row.frame}: differs and is not listed: bumble #{row.bumble.inspect}, erxos #{row.erxos.inspect}"
    end
    listed_wrongly = listed.filter_map do |frame, entry|
      row = by_frame[frame]
      if row.nil? then "#{frame}: listed, but not in the corpus"
      elsif row.agree? then "#{frame}: listed, but erXos and Bumble agree on #{row.erxos.inspect}"
      elsif row.erxos != entry.erxos then "#{frame}: listed with erxos #{entry.erxos.inspect}, gives #{row.erxos.inspect}"
      end
    end
    unlisted + listed_wrongly
  end

  def test_erxos_and_bumble_agree_but_where_listed
    failures = self.class.failures(self.class.compared, self.class.differences)
    assert_empty failures, "test/bt/differences.txt does not account for:\n#{failures.join("\n")}"
  end

  REFUSALS = %w[rejected unparsed].freeze

  # The samples decode alike, so the comparison is not of two refusals.
  def test_every_sample_decodes_alike
    rows = self.class.compared.to_h { |row| [row.frame, row] }
    SAMPLES.each do |codec, frames|
      frames.each do |frame|
        row = rows.fetch("#{codec} #{frame}")
        assert row.agree? && !REFUSALS.include?(row.erxos), "#{row.frame}: bumble #{row.bumble.inspect}, erxos #{row.erxos.inspect}"
      end
    end
  end

  # Seeded faults: a field read from the wrong place, or a length check dropped, in
  # either decoder must break the comparison.
  Seed = Data.define(:fault, :module_path, :anchor, :replacement)

  SEEDS = [
    Seed.new(fault: "Read Blob's offset read most significant octet first",
             module_path: ATT,
             anchor: 'decode(<<?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle:16/little, Offset:16/little>>) ->',
             replacement: 'decode(<<?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle:16/little, Offset:16/big>>) ->'),
    Seed.new(fault: "Central Identification's EDIV read from Rand's first two octets",
             module_path: SMP,
             anchor: '{central_identification, reversed(Ediv), reversed(Rand)};',
             replacement: '{central_identification, reversed(binary:part(Rand, 0, 2)), ' \
                          'reversed(<<Ediv/binary, (binary:part(Rand, 2, 6))/binary>>)};'),
    Seed.new(fault: 'Read Request taken with octets after its handle',
             module_path: ATT,
             anchor: 'decode(<<?ERX_ATT_OPCODE_READ_REQ, Handle:16/little>>) ->',
             replacement: 'decode(<<?ERX_ATT_OPCODE_READ_REQ, Handle:16/little, _/binary>>) ->'),
    Seed.new(fault: "LE Long Term Key Request's EDIV read most significant octet first",
             module_path: HCI,
             anchor: '<<Handle:16/little, Random:8/binary, Ediv:16/little>>) ->',
             replacement: '<<Handle:16/little, Random:8/binary, Ediv:16/big>>) ->'),
    Seed.new(fault: "Read Local Version's company identifier read from LMP_Subversion's place",
             module_path: HCI,
             anchor: "Company:16/little,\n#{' ' * 29}LmpSubversion:16/little>>",
             replacement: "LmpSubversion:16/little,\n#{' ' * 29}Company:16/little>>"),
    Seed.new(fault: "a signaling command's identifier read from its code's place",
             module_path: L2CAP,
             anchor: 'signal(<<_Code, Identifier, Length:16/little, Data/binary>>)',
             replacement: 'signal(<<Identifier, _Code, Length:16/little, Data/binary>>)')
  ].freeze

  SEEDS.each do |seed|
    define_method("test_seed_#{seed.fault.downcase.gsub(/[^a-z0-9]+/, '_')}") do
      text = File.read(File.join(ROOT, seed.module_path))
      assert_equal 1, text.scan(seed.anchor).size, "seed anchor for #{seed.fault} must occur once"
      faulty = self.class.compare(replaced: { seed.module_path => text.sub(seed.anchor, seed.replacement) })
      refute_empty self.class.failures(faulty, self.class.differences), "the comparison misses: #{seed.fault}"
    end
  end
end
