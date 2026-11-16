# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_session_relay_tests.erl, the cases of the terminal relay's
# server erx_session_relay (docs/design-shell.md, "The terminal relay's protocol")
# that belong to the edge around its core, compiled with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Each seeded
# fault is a copy of the server with one rule broken, which must fail the case that
# guards it.
class ErxSessionRelayTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = 'erlang/apps/erx_session/src/erx_session_relay.erl'
  CASES = %w[test/erlang/erx_session_relay_tests.erl].freeze
  DEADLINE = '120'
  # A broken rule: the text that keeps it in the server, what replaces it, and the
  # case that must then fail.
  Fault = Data.define(:text, :broken, :case_name)
  REPLY = "    gen_server:reply(From, Answer),\n    {noreply, carry_out(Actions, State#state{core = Core})}."
  WRITER = 'handle_info({tty_write, From, Ref, Bytes}, State)'
  FAULTS = {
    # The core's actions carried out before the answer goes.
    actions_before_answer: Fault.new(
      text: REPLY,
      broken: "    Acted = carry_out(Actions, State#state{core = Core}),\n    gen_server:reply(From, Answer),\n" \
              '    {noreply, Acted}.',
      case_name: /order_test/
    ),
    # A relay that takes a second name, which a process cannot hold.
    second_name: Fault.new(text: "init({Console, Origin}) ->\n",
                           broken: "init({Console, Origin}) ->\n    true = register(erx_relay_seed, self()),\n",
                           case_name: /the_name_test/),
    # A drain answered without giving the name up.
    name_kept: Fault.new(text: '_ = whereis(?NAME) =:= self() andalso unregister(?NAME),',
                         broken: '_ = whereis(?NAME),', case_name: /a_drain_gives_the_name_up_test/),
    # The core's monitors never made, so a group's end is never seen.
    unmonitored: Fault.new(text: 'State#state{monitored = Monitored#{Pid => erlang:monitor(process, Pid)}};',
                           broken: 'State;', case_name: /a_shell_that_ends_while_its_job_holds_test/),
    # A read's timer never started.
    timer_never_started: Fault.new(text: "    start_timer({timer, Timer}, Ms, State);\n",
                                   broken: "    _ = {Timer, Ms}, State;\n", case_name: /a_timed_read_test/),
    # A timer's message taken whatever its reference.
    any_timer: Fault.new(text: '#{Event := Ref} -> event(', broken: '#{Event := _} -> event(',
                         case_name: /forged_timers_are_ignored_test/),
    # The master's end taken as any other process's.
    master_end_ignored: Fault.new(text: "#state{master = {local, Pid, Ref}} = State) ->\n    event(",
                                  broken: "#state{master = {local, Pid, Ref}, console = none} = State) ->\n    event(",
                                  case_name: /the_masters_end_hangs_up_test/),
    # The master's 'DOWN' taken whatever its reference, so a forged one hangs the tty up.
    forged_master_down: Fault.new(text: "#state{master = {local, Pid, Ref}} = State) ->\n    event(",
                                  broken: "#state{master = {local, Pid, _}} = State) ->\n    event(",
                                  case_name: /malformed_messages_are_refused_test/),
    # A relay that outlives its console.
    outlives_console: Fault.new(text: "    {stop, normal, State};\n", broken: "    {noreply, State};\n",
                                case_name: /the_relay_ends_with_its_console_test/),
    # The console's 'DOWN' taken whatever its reference, so a forged one ends the relay.
    forged_console_down: Fault.new(text: '#state{console = {Pid, Ref}} = State) ->',
                                   broken: '#state{console = {Pid, _}} = State) ->',
                                   case_name: /malformed_messages_are_refused_test/),
    # A writer's reply address unchecked: the core is handed one that is no pid.
    unchecked_writer: Fault.new(text: "#{WRITER} when is_pid(From), is_reference(Ref) ->",
                                broken: "#{WRITER} ->",
                                case_name: /malformed_messages_are_refused_test/),
    # Any 'DOWN' taken for a process the relay watches, whatever its reference.
    any_down: Fault.new(text: '#{Pid := Ref} ->', broken: '#{Pid := _} ->',
                        case_name: /malformed_messages_are_refused_test/),
    # A group the core would monitor passed whatever it is.
    unchecked_group: Fault.new(text: "group_checked(_Group, _Request) ->\n    refused.",
                               broken: "group_checked(_Group, Request) ->\n    {ok, Request}.",
                               case_name: /malformed_messages_are_refused_test/),
    # An enveloped message taken as the master's from any domain.
    any_domain: Fault.new(text: '#state{master = {domain, _Pid, D}} = State) ->',
                          broken: '#state{master = {domain, _Pid, _}} = State) ->',
                          case_name: /a_master_in_another_domain_test/)
  }.freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_key do |name|
    define_method(:"test_fault_#{name}_fails") { assert_fault_fails(name) }
  end

  private

  def assert_fault_fails(name)
    fault = FAULTS.fetch(name)
    source = File.binread(File.join(ROOT, SOURCE))
    flunk "#{SOURCE} no longer holds #{fault.text.inspect}" unless source.include?(fault.text)

    output, status = eunit(SOURCE => source.sub(fault.text) { fault.broken })
    refute status.success?, output
    assert_match(/#{fault.case_name.source}\S*\.\.\.\*failed\*/, output)
  end

  def eunit(replaced)
    Dir.mktmpdir('erx-session-relay-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      # The relays the cases kill and the seeds crash would log reports
                      # into the lines the faults' cases are matched in.
                      'logger:set_primary_config(level, none), ' \
                      'halt(case eunit:test(erx_session_relay_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
