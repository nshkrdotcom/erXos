# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The fuzz target of the mailbox answer check (tools/fuzz/vc_property_fuzz.c), which reads
# the property buffer the firmware writes: built with the gate's own command, its seeds
# pass over kernel/core/vc_property.c as it is, and they catch seeded faults in the bounds
# that keep the firmware's length from reaching past the window.
class VcPropertyFuzzTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = File.join(ROOT, 'kernel/core/vc_property.c')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # name => [original, replacement]; the seeds must catch each.
  MUTANTS = {
    'the window clamp removed' => ['length < spec->window_bytes ? length : spec->window_bytes', 'length'],
    'the copy past the answer' => ['at < answer.length ? value[at]', 'at < ERX_VC_WINDOW_MAX ? value[at]'],
    'the least answer unchecked' => [') < spec->least_bytes', ') > UINT32_MAX - 1'],
    'the pin word unchecked' => ['words[ERX_VC_VALUE_WORD] == 0 ? ERX_OK : ERX_ENOTSUP', 'ERX_OK'],
    'result_word ignored' => ['(spec->result_word && indicator == 0)', '(false && indicator == 0)']
  }.freeze

  def test_the_seeds_pass_over_the_core
    Dir.mktmpdir('erx-vc-property-fuzz-') do |directory|
      output, status = run_fuzz(directory, CORE)
      assert status.success?, output
    end
  end

  def test_the_seeds_catch_seeded_faults
    MUTANTS.each do |name, (original, replacement)|
      Dir.mktmpdir('erx-vc-property-fuzz-mutant-') do |directory|
        output, status = run_fuzz(directory, mutate(directory, original, replacement))
        refute status.success?, "the fuzz target did not catch the seeded fault: #{name}"
        assert_match(/deadly signal/, output, "the fuzz program failed for another reason: #{name}")
      end
    end
  end

  private

  def target = Erx::PackFuzz.targets.find { |candidate| candidate.kind == 'vc_property' }

  def mutate(directory, original, replacement)
    source = File.read(CORE)
    raise "mutation site is gone: #{original}" unless source.include?(original)

    path = File.join(directory, 'vc_property.c')
    File.write(path, source.sub(original) { replacement })
    path
  end

  # Builds the fuzz program with the gate's own command, core standing in for the target's
  # source, and runs it once over the target's seeds.
  def run_fuzz(directory, core)
    refute_nil target, 'vc_property fuzz target is not declared'
    corpus = File.join(directory, 'corpus')
    FileUtils.mkdir_p(corpus)
    target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(directory, 'fuzz')
    command = Erx::PackFuzz.compile_command(target, root: ROOT, compiler: COMPILER, program: program)
    assert_includes command, CORE, 'the gate no longer builds the core this test substitutes'
    command = command.map { |argument| argument == CORE ? core : argument }
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, '-runs=0',
                    corpus, stdin_data: '', chdir: directory)
  end
end
