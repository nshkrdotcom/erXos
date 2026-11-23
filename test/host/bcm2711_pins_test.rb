# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/generated_tree'

# Judges the functions of the BCM2711's on-board pins that the root sets at boot,
# kernel/core/bcm2711_pins.c (docs/design-header-io.md, "On-board pins"), through
# test/fixtures/bcm2711_pins_driver.c: each row's FSEL field takes its alternate's code and
# every other field keeps what was read; a word the rows change loses its reserved bits; a
# row of bank 0 (the header's pins), a pin past GPIO 57, an alternate past 5 or too many
# rows refuses the whole plan and changes nothing. It also judges the root's shim around the
# core, liberx/backend/fiasco/bcm2711_pins.c, through test/fixtures/fiasco_bcm2711_pins_driver.c
# over a register block in memory: a window too short for the six registers or a refused
# plan writes nothing, and a word that reads back otherwise is a mismatch, never set. Seeded faults must each change a pinned answer.
class Bcm2711PinsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'kernel/core/bcm2711_pins.c'
  DRIVER = 'test/fixtures/bcm2711_pins_driver.c'
  SHIM = 'liberx/backend/fiasco/bcm2711_pins.c'
  SHIM_DRIVER = 'test/fixtures/fiasco_bcm2711_pins_driver.c'

  # The core's reserved-bit clearing, and the edit that removes it.
  CLEARING = ['next.word[reg] &= fields[reg];', 'next.word[reg] &= fields[reg] | ~fields[reg];'].freeze

  # name => [original, replacement]; each must change the answers of test_answers.
  MUTANTS = {
    # A field one pin off: GPIO 30's row writes FSEL31.
    'a field one pin off' => ['erx_bcm2711_gpio_gpfsel3_fsel30_set(', 'erx_bcm2711_gpio_gpfsel3_fsel31_set('],
    # A whole-register write, which zeroes the fields no row names, FSEL34 to 39 among them.
    'a whole-register write' => ['fsel30_set(fsel->word[3], code', 'fsel30_set(0, code'],
    # A plan taken in part: a bad row ends the rows instead of refusing the plan.
    'a plan taken in part' => ["\t\t\treturn (false);\n\tfor (uint32_t reg", "\t\t\tbreak;\n\tfor (uint32_t reg"],
    # ALT4 and ALT5 swapped, as a table in alternate order would have them.
    'ALT4 and ALT5 swapped' => ['ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4, ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5',
                                'ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5, ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4'],
    # A changed word kept with its reserved bits, which the generated write refuses.
    'reserved bits kept' => CLEARING,
    # Every word masked, so a word no row names loses its reserved bits and would be written.
    'every word masked' => ["\t\tif (next.word[reg] != fsel->word[reg])\n\t\t\tnext", "\t\tnext"]
  }.freeze

  ZERO = '0 0 0 0 0 0'
  UART0 = '30:3 31:3 32:3 33:3'

  # The requests the tests pin, and the answers the design gives them.
  ANSWERS = [
    # The board's reading (docs/research-bluetooth-pi4.md, its 2026-11-23 section): the
    # firmware set GPIO 32 and 33 to ALT3 and left 30 and 31 inputs; the four rows make GPFSEL3 0xfff, and the
    # other registers, here arbitrary words, are not touched.
    ["plan 01234567 089abcde 12345678 00000fc0 3fffffff 00ffffff #{UART0}",
     'plan 01234567 089abcde 12345678 00000fff 3fffffff 00ffffff'],
    # FSEL34 to 39, the WiFi chip's SDIO pins, which no row names, keep what was read.
    ['plan 0 0 0 3ffff000 0 0 30:3 31:3', 'plan 00000000 00000000 00000000 3ffff03f 00000000 00000000'],
    # Banks 1 and 2's edges: GPIO 28 in GPFSEL2 beside bank 0's 20 to 27, ALT5 coded 2; GPIO
    # 57, GPFSEL5's last field, ALT0 coded 4; ALT4 is coded 3.
    ['plan 0 0 3fffffff 0 0 0 28:5', 'plan 00000000 00000000 3affffff 00000000 00000000 00000000'],
    ["plan #{ZERO} 57:0", 'plan 00000000 00000000 00000000 00000000 00000000 00800000'],
    ["plan #{ZERO} 40:4", 'plan 00000000 00000000 00000000 00000000 00000003 00000000'],
    # A later row of one pin wins; no rows change nothing.
    ["plan #{ZERO} 30:3 30:0", 'plan 00000000 00000000 00000000 00000004 00000000 00000000'],
    ['plan 0 0 0 00000fc0 0 0', 'plan 00000000 00000000 00000000 00000fc0 00000000 00000000'],
    # A word the rows change loses its reserved bits, GPFSEL3's 30 and 31; the words they
    # leave as read keep theirs, since they are not written.
    ["plan 0 0 0 c0000fc0 ffffffff ff000000 #{UART0}", 'plan 00000000 00000000 00000000 00000fff ffffffff ff000000'],
    # Bank 0's pins, the console's GPIO 14 and 15 among them, a pin past GPIO 57, an
    # alternate past 5, and a 31st row refuse the plan whole, even after valid rows.
    ["plan 0 0 0 00000fc0 0 0 #{UART0} 27:3", 'refused 00000000 00000000 00000000 00000fc0 00000000 00000000'],
    ["plan #{ZERO} 14:5", "refused #{%w[00000000] * 6 * ' '}"],
    ["plan #{ZERO} 0:0", "refused #{%w[00000000] * 6 * ' '}"],
    ["plan #{ZERO} 58:0", "refused #{%w[00000000] * 6 * ' '}"],
    ["plan #{ZERO} 30:6", "refused #{%w[00000000] * 6 * ' '}"],
    ["plan #{ZERO} #{(28..57).map { |gpio| "#{gpio}:0" }.join(' ')}",
     'plan 00000000 00000000 24000000 24924924 24924924 00924924'],
    ["plan #{ZERO} #{(28..57).map { |gpio| "#{gpio}:0" }.join(' ')} 30:3", "refused #{%w[00000000] * 6 * ' '}"]
  ].freeze

  # The shim's requests: the window's length, the six words the block holds and the rows;
  # its answers: the outcome and the six words the block holds after.
  SHIM_ANSWERS = [
    # Only GPFSEL3 changes and only it is written: the others keep their reserved bits.
    ["apply 24 0 0 0 c0000fc0 ffffffff ff000000 #{UART0}", 'set 00000000 00000000 00000000 00000fff ffffffff ff000000'],
    # A window of four registers: GPFSEL4 cannot be read, so nothing is written, GPFSEL3 included.
    ["apply 16 0 0 0 00000fc0 0 0 #{UART0}", 'refused 00000000 00000000 00000000 00000fc0 00000000 00000000'],
    # A refused plan writes nothing.
    ["apply 24 0 0 0 00000fc0 0 0 #{UART0} 14:5", 'refused 00000000 00000000 00000000 00000fc0 00000000 00000000'],
    # Rows that change nothing write nothing, and the words read back as planned.
    ['apply 24 0 0 0 00000fff 0 0 30:3 31:3', 'set 00000000 00000000 00000000 00000fff 00000000 00000000']
  ].freeze

  # Under a core that keeps reserved bits, GPFSEL5's write is refused and the word keeps what
  # it held, as a register that does not take the word would: it reads back otherwise.
  MISMATCH = ['apply 24 0 0 0 0 0 ff000000 57:0', 'mismatch 00000000 00000000 00000000 00000000 00000000 ff000000'].freeze

  # name => [original, replacement] in the shim; each must change a shim answer.
  SHIM_MUTANTS = {
    # GPFSEL5's readback skipped, so a word that did not take the write is reported set.
    'a readback skipped' => ["reg < ERX_BCM2711_PINS_REGISTERS; reg++)\n\t\tif (after",
                             "reg < ERX_BCM2711_PINS_REGISTERS - 1; reg++)\n\t\tif (after"],
    # A window too short read in part, so the words it covers are written.
    'a short window written' => ["\tif (!fsel_read(device, &read))\n\t\treturn (ERX_FIASCO_BOARD_PINS_REFUSED);",
                                 "\tread = (erx_bcm2711_fsel_t){ { 0 } };\n\t(void)fsel_read(device, &read);"]
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-bcm2711-pins-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(sources, name:)
    output = File.join(@directory, name.tr(" '", '--'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  *sources, '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def ask(program, requests)
    output, status = Open3.capture2e(program, stdin_data: requests.map { |request, _| "#{request}\n" }.join)
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  # Writes source with original replaced into the scratch directory and returns its path.
  def mutant(source, original, replacement, name:)
    assert_equal 1, source.scan(original).size, "the mutant #{name} no longer applies"
    path = File.join(@directory, "#{name.tr(" '", '--')}.c")
    File.write(path, source.sub(original, replacement))
    path
  end

  def core_answers(core: File.join(ROOT, CORE), name: 'driver')
    ask(build([core, File.join(ROOT, DRIVER)], name: name), ANSWERS)
  end

  # The shim's answers, the last under a core that keeps reserved bits.
  def shim_answers(shim: File.join(ROOT, SHIM), name: 'shim')
    source = File.read(File.join(ROOT, CORE))
    keeping = mutant(source, *CLEARING, name: "#{name} core keeping reserved bits")
    ask(build([File.join(ROOT, CORE), shim, File.join(ROOT, SHIM_DRIVER)], name: name), SHIM_ANSWERS) +
      ask(build([keeping, shim, File.join(ROOT, SHIM_DRIVER)], name: "#{name} mismatch"), [MISMATCH])
  end

  def test_answers
    assert_equal ANSWERS.map(&:last), core_answers
  end

  def test_each_seeded_fault_changes_an_answer
    source = File.read(File.join(ROOT, CORE))
    MUTANTS.each do |name, (original, replacement)|
      refute_equal ANSWERS.map(&:last), core_answers(core: mutant(source, original, replacement, name: name), name: name),
                   "the mutant #{name} survived"
    end
  end

  def test_shim_answers
    assert_equal [*SHIM_ANSWERS.map(&:last), MISMATCH.last], shim_answers
  end

  def test_each_seeded_shim_fault_changes_an_answer
    source = File.read(File.join(ROOT, SHIM))
    SHIM_MUTANTS.each do |name, (original, replacement)|
      shim = mutant(source, original, replacement, name: "shim #{name}")
      refute_equal [*SHIM_ANSWERS.map(&:last), MISMATCH.last], shim_answers(shim: shim, name: "shim #{name}"),
                   "the shim mutant #{name} survived"
    end
  end
end
