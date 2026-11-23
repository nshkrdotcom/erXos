# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pins_bcm2711_tests.erl and erx_pins_core_tests.erl, the pure
# cores' rows of docs/design-pinctrl.md's host tests: the BCM2711's planner, its check by
# planning again over erx_pins_model, and the start's verdict and the release's choice
# of configuration, on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies), against the sources as they are and against each seeded fault, where the
# named case must fail.
class ErxPinsTest < Minitest::Test
  APPLICATIONS = %w[erx_pins].freeze
  TESTS = %w[
    test/erlang/erx_pins_model.erl
    test/erlang/erx_pins_bcm2711_tests.erl
    test/erlang/erx_pins_core_tests.erl
  ].freeze
  MODULES = '[erx_pins_bcm2711_tests, erx_pins_core_tests]'
  DEADLINE_SECONDS = '300'
  KIND = 'erlang/apps/erx_pins/src/erx_pins_bcm2711.erl'
  CORE = 'erlang/apps/erx_pins/src/erx_pins_core.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'each function field one pin off', module_path: KIND,
             anchor: 'function_shift(Pin) -> ?FUNCTION_WIDTH * (Pin rem 10).',
             replacement: 'function_shift(Pin) -> ?FUNCTION_WIDTH * ((Pin + 1) rem 10).',
             catching_case: 'uart0_from_the_board_reading_test'),
    Seed.new(fault: 'a whole-register write, which zeroes GPIO 34 to 39', module_path: KIND,
             anchor: '                     lists:sum([field_mask(Field) || Field <- Differing]),',
             replacement: '                     ?WORD_MAX,',
             catching_case: 'uart0_from_the_board_reading_test'),
    Seed.new(fault: 'ALT4 and ALT5 swapped', module_path: KIND,
             anchor: '     ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4, ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5}.',
             replacement: '     ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5, ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4}.',
             catching_case: 'alternate_codes_test'),
    Seed.new(fault: "a refused pin dropped and the other pins' steps returned", module_path: KIND,
             anchor: '    [checked(Entry) || Entry <- Wanted];',
             replacement: '    [Entry || {Pin, _} = Entry <- Wanted, valid_pin(Pin)];',
             catching_case: 'refused_plan_returns_no_step_test'),
    Seed.new(fault: 'the second plan replaced by ok', module_path: CORE,
             anchor: '        {ok, Steps} -> {ok, lists:usort(lists:append([element(2, Step) || Step <- Steps]))};',
             replacement: '        {ok, _Steps} -> {ok, []};',
             catching_case: 'check_by_planning_again_test'),
    Seed.new(fault: 'a step that does not carry its pins', module_path: KIND,
             anchor: '        _ -> {true, {field, [Field#field.pin || Field <- Differing], Register,',
             replacement: '        _ -> {true, {field, [], Register,',
             catching_case: 'check_by_planning_again_test'),
    Seed.new(fault: 'the "only what differs" rule removed', module_path: KIND,
             anchor: '                          not field_agrees(Read, Field)],',
             replacement: '                          is_integer(word(Read, R, Field#field.pin))],',
             catching_case: 'idempotent_test'),
    Seed.new(fault: 'the command left out because the level register reads 1', module_path: KIND,
             anchor: '    Function =:= Output andalso (word(Read, bank(gplev, Pin), Pin) bsr (Pin rem 32)) band 1 =:= Level.',
             replacement: '    is_integer(Function + Output) andalso (word(Read, bank(gplev, Pin), Pin) bsr (Pin rem 32)) band 1 =:= Level.',
             catching_case: 'level_is_a_command_test'),
    Seed.new(fault: 'a GPSET word that carries other bits of a reading', module_path: KIND,
             anchor: '    commands(gpset, [Pin || {Pin, 1} <- Pending]) ++ commands(gpclr, [Pin || {Pin, 0} <- Pending]).',
             replacement: '    [{command, P, R, B bor word(Read, bank(gplev, 0), 0)} || ' \
                          '{command, P, R, B} <- commands(gpset, [Pin || {Pin, 1} <- Pending])] ++ ' \
                          'commands(gpclr, [Pin || {Pin, 0} <- Pending]).',
             catching_case: 'level_is_a_command_test'),
    Seed.new(fault: "the event word written back as read, which clears GPIO 15's event", module_path: KIND,
             anchor: '        {ok, Fired, commands(gpeds, Fired)}',
             replacement: '        {ok, Fired, [{command, Fired, gpeds0, word(Read, gpeds0, 0)} || Fired =/= []]}',
             catching_case: 'events_acknowledge_own_pins_test'),
    Seed.new(fault: 'up and down swapped', module_path: KIND,
             anchor: "pull_code(up) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_UP;\n" \
                     'pull_code(down) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_DOWN.',
             replacement: "pull_code(up) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_DOWN;\n" \
                          'pull_code(down) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_UP.',
             catching_case: 'pulls_up_and_down_test'),
    Seed.new(fault: 'a row without a pull writing none', module_path: KIND,
             anchor: '     || {Pin, #{pull := Pull}} <- Settings].',
             replacement: '     || {Pin, Setting} <- Settings, Pull <- [maps:get(pull, Setting, none)]].',
             catching_case: 'no_pull_written_without_one_test'),
    Seed.new(fault: 'the function written before the level', module_path: KIND,
             anchor: "                           level_steps(Read, Settings),\n" \
                     "                           field_steps(Read, function_fields(Settings)),\n",
             replacement: "                           field_steps(Read, function_fields(Settings)),\n" \
                          "                           level_steps(Read, Settings),\n",
             catching_case: 'write_order_test'),
    Seed.new(fault: 'a field taken without its mask', module_path: KIND,
             anchor: '    (Word band field_mask(Field)) bsr Field#field.shift =:= Code.',
             replacement: '    Word bsr Field#field.shift =:= Code.',
             catching_case: 'total_over_any_reading_test_'),
    Seed.new(fault: 'bits of the reading carried into a field write past its mask', module_path: KIND,
             anchor: '                     lists:sum([Field#field.code bsl Field#field.shift || Field <- Differing])}}',
             replacement: '                     lists:sum([Field#field.code bsl Field#field.shift || Field <- Differing]) ' \
                          'bor word(Read, Register, none)}}',
             catching_case: 'total_over_any_reading_test_'),
    Seed.new(fault: 'default planned for a device with other states', module_path: CORE,
             anchor: 'states(Table, Device) =:= [default]],',
             replacement: 'lists:member(default, states(Table, Device))],',
             catching_case: 'start_plan_test'),
    Seed.new(fault: 'the normal start answering ok with the pin only logged', module_path: CORE,
             anchor: "                [] -> {ok, Report};\n                _ -> {error, {unset, Report}}\n",
             replacement: "                Failing when is_list(Failing) -> {ok, Report}\n",
             catching_case: 'a_device_only_normal_uses_left_unset_test'),
    Seed.new(fault: 'the rescue start failing on a device rescue does not use', module_path: CORE,
             anchor: 'used_by(normal, Configuration) -> Configuration =:= normal;',
             replacement: 'used_by(normal, Configuration) -> is_atom(Configuration);',
             catching_case: 'a_device_only_normal_uses_left_unset_test'),
    Seed.new(fault: 'rescue chosen when a device rescue uses is named', module_path: CORE,
             anchor: '    not lists:any(fun(#{uses := Uses}) -> Uses =:= rescue end, Report);',
             replacement: '    is_list(Report);',
             catching_case: 'a_device_rescue_uses_left_unset_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-pins-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', "halt(case eunit:test(#{MODULES}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
