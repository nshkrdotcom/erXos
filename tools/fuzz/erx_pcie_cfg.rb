# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_pcie_cfg, the PCIe configuration-space parser and BAR sizing
# (test/erlang/erx_pcie_cfg_fuzz.erl), compiled from source with the cases whose
# snapshot writers and fixtures it draws on, and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's). It runs the module as it is, then each seeded copy, which
# must fail with its marker: one without the bound on the MSI-X table's BAR indicator,
# whose lookup past the six BARs crashes; one without the bound on the table's end; one
# that lets an MSI-X capability's structure run past the snapshot; one whose sizing
# takes a mask with holes; and one whose sizing places a BAR of 4 GiB or more. Each shows the generated inputs reach that bound and the target sees past it.
module ErxPcieCfgFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_pcie/src/erx_pcie_cfg.erl')
  SOURCES = %w[erx_pcie_cfg_tests erx_pcie_cfg_fuzz].map { |name| File.join(ROOT, "test/erlang/#{name}.erl") }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Seed = Data.define(:fault, :anchor, :replacement, :marker)
  SEEDS = [
    Seed.new(fault: "the MSI-X table's BAR indicator left unbounded",
             anchor: 'check(Indicator < ?ERX_PCIE_NORMAL_BARS',
             replacement: 'check(Indicator >= 0',
             marker: 'crash'),
    Seed.new(fault: "the MSI-X table's end left unbounded",
             anchor: 'Entries * ?ERX_PCIE_MSIX_ENTRY_SIZE =< 1 bsl 32,',
             replacement: 'Entries * ?ERX_PCIE_MSIX_ENTRY_SIZE =< 1 bsl 64,',
             marker: 'out_of_bounds'),
    Seed.new(fault: "an MSI-X capability's structure left unbounded",
             anchor: 'fits(At, ?ERX_PCIE_MSIX_PBA + 4, msix),',
             replacement: 'ok,',
             marker: 'out_of_bounds'),
    Seed.new(fault: 'a sizing mask with holes taken',
             anchor: 'case contiguous(Bits, Lowest, Width) of',
             replacement: 'case true of',
             marker: 'out_of_bounds'),
    Seed.new(fault: 'a BAR of 4 GiB or more sized',
             anchor: 'Log2 > ?ERX_PCIE_BAR_SIZE_LOG2_MAX ->',
             replacement: 'Log2 > 63 ->',
             marker: 'out_of_bounds')
  ].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted, \d+ sized$/)
    SEEDS.each do |planted|
      raise "seed anchor for #{planted.fault} is not unique" unless source.scan(planted.anchor).size == 1

      output, status = fuzz(source.sub(planted.anchor) { planted.replacement }, seed: seed)
      abort("#{planted.fault} passed:\n#{output}") if status.success? || !output.include?(planted.marker)
    end
    puts 'erx_pcie_cfg keeps every bound under fuzzing, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-pcie-cfg-fuzz') do |work|
      module_path = File.join(work, 'erx_pcie_cfg.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_pcie_cfg_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxPcieCfgFuzz.run(seed: options.fetch(:seed))
end
