# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/generated_tree'

# Judges the board's hardware watchdog behind the kernel's, kernel/core/pm_wdt.c
# (docs/design-platforms.md, "The watchdog"), through test/fixtures/pm_wdt_driver.c: the
# watchdog's start arms it, each tick reloads it once armed, nothing writes it once an end
# is taken, and each write puts the 4 s timeout with the password in WDOG and selects the
# full reset in RSTC, keeping the bits no source names. Seeded faults must each change a
# pinned answer.
class PmWdtTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'kernel/core/pm_wdt.c'
  DRIVER = 'test/fixtures/pm_wdt_driver.c'

  # name => [original, replacement]; each must change the answers of test_answers.
  MUTANTS = {
    'the arming skipped' =>
      ['return (action == ERX_WATCHDOG_ARM || (action == ERX_WATCHDOG_RELOAD && armed));',
       'return (action == ERX_WATCHDOG_RELOAD && armed);'],
    'a reload with the wrong password' => ['ERX_PM_WDT_WDOG_PASSWD_KEY, &words.wdog', '0x5b, &words.wdog'],
    'reloads after an end' => ["\tif (ending)\n\t\treturn (false);\n", "\t(void)ending;\n"],
    'a reload that arms' => ['(action == ERX_WATCHDOG_RELOAD && armed)', '((void)armed, action == ERX_WATCHDOG_RELOAD)'],
    'the timeout in seconds' => ['ERX_PM_WDT_TIMEOUT_S * ERX_PM_WDT_UNITS_PER_S, &words.wdog', 'ERX_PM_WDT_TIMEOUT_S, &words.wdog'],
    'RSTC without the password' => ["\t(void)erx_pm_wdt_rstc_passwd_set(words.rstc, ERX_PM_WDT_RSTC_PASSWD_KEY, &words.rstc);\n", '']
  }.freeze

  # The requests the tests pin, and the answers the design gives them.
  ANSWERS = [
    # The start arms, whatever was before; a tick reloads only an armed watchdog.
    ['writes arm 0 0', 'writes 1'], ['writes reload 1 0', 'writes 1'], ['writes reload 0 0', 'writes 0'],
    ['writes none 1 0', 'writes 0'], ['writes end 1 0', 'writes 0'],
    # Once an end is taken nothing is written, so the end's reset is never pushed out.
    ['writes arm 0 1', 'writes 0'], ['writes reload 1 1', 'writes 0'],
    # 4 s is 0x40000 units of 1/65536 s, with the password 0x5a in the top byte.
    ['words 0', 'words 5a040000 5a000020'],
    # RSTC's reset configuration becomes the full reset; its other bits stay as read and
    # its top byte, whatever it read, is the password.
    ['words 00000030', 'words 5a040000 5a000020'], ['words 00000102', 'words 5a040000 5a000122'],
    ['words ffffffff', 'words 5a040000 5affffef']
  ].freeze

  def setup
    @directory = Dir.mktmpdir('erx-pm-wdt-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core: File.join(ROOT, CORE), name: 'driver')
    output = File.join(@directory, name.tr(" '", '--'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def ask(program)
    output, status = Open3.capture2e(program, stdin_data: ANSWERS.map { |request, _| "#{request}\n" }.join)
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  def test_answers
    assert_equal ANSWERS.map(&:last), ask(build)
  end

  def test_each_seeded_fault_changes_an_answer
    source = File.read(File.join(ROOT, CORE))
    MUTANTS.each do |name, (original, replacement)|
      assert_equal 1, source.scan(original).size, "the mutant #{name} no longer applies"
      core = File.join(@directory, "#{name.tr(" '", '--')}.c")
      File.write(core, source.sub(original, replacement))
      refute_equal ANSWERS.map(&:last), ask(build(core: core, name: name)), "the mutant #{name} survived"
    end
  end
end
