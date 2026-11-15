# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# The spawn planner (liberx/program/spawn_plan.c) through test/fixtures/spawn_plan_driver.c,
# under the address and undefined sanitizers: hand-built spawns plan as FreeBSD's
# posix_spawn would leave the child, and seeded random starters' tables and file actions
# plan as the model in tools/fuzz/spawn_plan_fuzz.c replays them, each plan naming only
# objects the child holds after exec and each object once, a refused plan leaving its
# inputs as they were (docs/design-programs.md, "Starting a program" and "Verification and
# testing"). The random cases reach each verdict of VERDICTS, and each seeded fault must
# fail a random case's check, which aborts.
class SpawnPlanTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  PLANNER = 'liberx/program/spawn_plan.c'
  SOURCES = [PLANNER, 'tools/fuzz/spawn_plan_fuzz.c', 'test/fixtures/spawn_plan_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  SEED = 0x5350_4157
  # The signal a failed check ends the driver with.
  ABORTED = Signal.list.fetch('ABRT')
  COUNT = 20_000
  # The verdicts the random cases must reach besides acceptance, by name.
  VERDICTS = %i[ENOENT E2BIG EBADF EFAULT ENOTDIR EMFILE ENAMETOOLONG ENOSYS].freeze

  # name => [file, original, replacement]: bounds off by one, a dropped close-on-exec, a
  # dup2 that keeps its source's FD_CLOEXEC, a mem range handed on, an object named
  # twice, and a ".." that cannot take back a component past the bound.
  MUTANTS = {
    'argv and env one byte past ERX_PROG_ARGS_MAX pass' =>
      [PLANNER, "\t\tif (len >= ERX_PROG_ARGS_MAX - *bytes)\n", "\t\tif (len > ERX_PROG_ARGS_MAX - *bytes)\n"],
    'a descriptor with FD_CLOEXEC is handed on' =>
      [PLANNER, "\t\tif (cloexec[fd]) {\n\t\t\tslot->kind = ERX_SPAWN_FD_NONE;\n\t\t\tcontinue;\n\t\t}\n", "\t\t(void)cloexec[fd];\n"],
    'adddup2 keeps FD_CLOEXEC' =>
      [PLANNER, "\t\tplan->fds[action->fd] = plan->fds[action->src];\n\t\tcloexec[action->fd] = false;\n",
       "\t\tplan->fds[action->fd] = plan->fds[action->src];\n\t\tcloexec[action->fd] = cloexec[action->src];\n"],
    'a path of ERX_PROG_PATH_MAX bytes is too long' =>
      [PLANNER, "\t\t\tif (beyond > 0 || n >= ERX_PROG_PATH_MAX - len) {\n",
       "\t\t\tif (beyond > 0 || n + 1 >= ERX_PROG_PATH_MAX - len) {\n"],
    'a mem range is handed on' =>
      [PLANNER, "\t\tcase ERX_PROG_OBJ_MEM:\n\t\t\tslot->kind = ERX_SPAWN_FD_NONE;\n\t\t\tbreak;\n",
       "\t\tcase ERX_PROG_OBJ_MEM:\n\t\t\tbreak;\n"],
    'an object is named at two numbers' =>
      [PLANNER, "\t\tif (plan->fds[fd].kind == ERX_SPAWN_FD_NONE)\n\t\t\tcontinue;\n\t\tfor (uint16_t first",
       "\t\tif (plan->fds[fd].kind != ERX_SPAWN_FD_DUP)\n\t\t\tcontinue;\n\t\tfor (uint16_t first"],
    'a ".." past the bound takes off a component that fits' =>
      [PLANNER, "\t\t\tif (beyond > 0) {\n", "\t\t\tif (false) {\n"]
  }.freeze

  def test_hand_built_spawns_plan_as_freebsd_leaves_the_child
    with_driver({}) do |driver|
      output, status = run_driver(driver, 'examples')
      assert status.success?, output
      refute_empty output.lines
      assert(output.lines.all? { |line| line.start_with?('ok ') }, output)
    end
  end

  def test_random_tables_and_actions_plan_as_the_model_replays_them
    with_driver({}) do |driver|
      output, status = run_driver(driver, 'random', SEED.to_s, COUNT.to_s)
      assert status.success?, output
      verdicts = output.scan(/^errno (\d+) (\d+)$/).to_h { |errno, count| [errno.to_i, count.to_i] }
      assert_operator output[/^accepted (\d+)$/, 1].to_i, :>, COUNT / 20, output
      VERDICTS.each do |name|
        assert_operator verdicts.fetch(Errno.const_get(name)::Errno, 0), :>, 0, "no case refused with #{name}"
      end
    end
  end

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, (file, original, replacement)|
      source = File.read(File.join(ROOT, file))
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
      with_driver({ file => source.sub(original, replacement) }) do |driver|
        output, status = run_driver(driver, 'random', SEED.to_s, COUNT.to_s)
        assert_equal ABORTED, status.termsig, "seeded fault not caught by a check: #{name}\n#{output}"
      end
    end
  end

  private

  # Builds the driver from SOURCES, each source named in replaced taking the text it maps to.
  def with_driver(replaced)
    Dir.mktmpdir('erx-spawn-plan-') do |directory|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(directory, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
      end
      binary = File.join(directory, 'driver')
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include')]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes, *sources, '-o', binary, stdin_data: '')
      assert status.success?, "compiling the driver failed:\n#{output}"
      yield binary
    end
  end

  def run_driver(driver, *arguments)
    Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, 'gtimeout', '-k', '10', '300', driver, *arguments,
                    stdin_data: '')
  end
end
