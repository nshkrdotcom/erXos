# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the domain service (docs/design-system.md, "System
# services"), compiled with warnings as errors on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies): test/erlang/erx_domain_tests.erl
# for erx_ident, erx_domain_core and erx_domain_srv over a stand-in for the
# domain library's NIF module, and test/erlang/erx_domain_links_tests.erl,
# the exhaustive exploration of the connection protocol's core,
# test/erlang/erx_domain_mints_tests.erl, the exhaustive exploration of the
# core that mints facets configured domains serve,
# test/erlang/erx_domain_mints_srv_tests.erl for the service applying that core, and
# test/erlang/erx_facet_tests.erl for the facet behaviour, erx_facet, which the
# service mints facets of, and test/erlang/erx_devices_tests.erl for erx_devices,
# the catalogue presented unchanged, test/erlang/erx_driver_ctl_tests.erl for
# erx_driver_ctl, the driver-control facet, and erx_blk_sup behind it, and
# test/erlang/erx_devfs_tests.erl for /dev, erx_devfs and erx_devfs_core, with the
# erx_fs behaviour and the schema's and text's modules they call. Each fault of
# FAULTS replaces one passage of one of these sources (/dev's tree, the inspect facet's scope
# or the domain service's funnel for a domain's facets), and the case it names must fail.
class ErxDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = 'erlang/apps/erx_domain/src'
  # The applications are compiled whole (ErlangBuild): the domain service, the facet and
  # inspection modules of erx, the driver supervisor of erx_blk, and the erx_fs behaviour and
  # the grants of erx_files that /dev's tree and a test files service use.
  APPLICATIONS = %w[erx erx_files erx_blk erx_domain].freeze
  # erx_9p_grammar is generated into the preloaded sources of OTP and erx_path is preloaded, both
  # outside the applications; erx_ns_prim_stub stands in for prim_file under the system domain's /data mount.
  TESTS = %w[
    build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl
    otp/erts/preloaded/src/erx_path.erl
    test/erlang/erx_ns_prim_stub.erl
    test/erlang/erx_devfs_tests.erl
    test/erlang/erx_fs_test_tree.erl
    test/erlang/erx_driver_ctl_tests.erl
    test/erlang/erx_facet_tests.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/erx_domain_fake_lib.erl
    test/erlang/erx_domain_tests.erl
    test/erlang/erx_domain_links_tests.erl
    test/erlang/erx_domain_mints_tests.erl
    test/erlang/erx_domain_mints_srv_tests.erl
    test/erlang/erx_devices_tests.erl
    test/erlang/erx_devices_pci_core_tests.erl
    test/erlang/erx_devices_pci_tests.erl
  ].freeze

  def test_domain_service_cases_pass_under_eunit
    assert_eunit_passes('erx_domain_tests', deadline: 120)
  end

  def test_facet_behaviour_cases_pass_under_eunit
    assert_eunit_passes('erx_facet_tests', deadline: 60)
  end

  def test_connection_protocol_core_passes_under_eunit
    assert_eunit_passes('erx_domain_links_tests', deadline: 300)
  end

  def test_facet_mint_core_passes_under_eunit
    assert_eunit_passes('erx_domain_mints_tests', deadline: 120)
  end

  def test_domain_service_applies_the_mint_core_under_eunit
    assert_eunit_passes('erx_domain_mints_srv_tests', deadline: 60)
  end

  def test_driver_control_facet_passes_under_eunit
    assert_eunit_passes('erx_driver_ctl_tests', deadline: 60)
  end

  def test_device_catalogue_presentation_passes_under_eunit
    assert_eunit_passes('erx_devices_tests', deadline: 60)
  end

  def test_device_service_pci_decisions_pass_under_eunit
    assert_eunit_passes('erx_devices_pci_core_tests', deadline: 60)
  end

  def test_device_service_pci_process_passes_under_eunit
    assert_eunit_passes('erx_devices_pci_tests', deadline: 60)
  end

  def test_dev_tree_passes_under_eunit
    assert_eunit_passes('erx_devfs_tests', deadline: 60)
  end

  # Each fault replaces one passage of one source of the service, and the case it names,
  # of the EUnit module tests, must fail.
  Fault = Data.define(:name, :file, :from, :to, :tests, :caught_by)
  SERVICE = File.join(APPLICATION, 'erx_domain_srv.erl')
  MINTS = File.join(APPLICATION, 'erx_domain_mints.erl')
  FAULTS = [
    # The read-only tree's own refusal of ctl, the seeded fault of P5b: without it the
    # tree walks to ctl, so a session holding only the read-only tree could reset a driver.
    Fault.new(name: 'a read-only tree that accepts ctl', file: File.join(APPLICATION, 'erx_devfs.erl'),
              from: %q{walk({device, Index}, <<"ctl">>, #{rights := rw}) ->},
              to: %q{walk({device, Index}, <<"ctl">>, _Fs) ->},
              tests: 'erx_devfs_tests', caught_by: 'the_read_only_tree_has_no_ctl_test'),
    # The inspect facet's scope (docs/design-live.md, "The inspect service"): a development
    # build that gives every principal's session the whole machine.
    Fault.new(name: 'scope all for every principal of a development build',
              file: File.join(APPLICATION, 'erx_domain_core.erl'),
              from: 'Development andalso lists:member(Principal, Roots)',
              to: 'Development andalso is_list(Roots)',
              tests: 'erx_domain_tests', caught_by: 'inspect_scope_test'),
    # The inspection agent's owner (docs/design-live.md, "The runtime agent"): a check of
    # the creation alone keeps a pid of another domain's node that carries this domain's id.
    Fault.new(name: 'an inspection agent checked by its creation alone',
              file: File.join(APPLICATION, 'erx_domain_pid.erl'),
              from: '{ok, Inspect} when is_pid(Inspect), node(Inspect) =:= Node ->',
              to: '{ok, Inspect} when is_pid(Inspect), is_atom(Node) ->',
              tests: 'erx_domain_tests', caught_by: 'inspect_agent_of_another_incarnation_test'),
    # The funnel's gates (docs/design.md, the facet table's chokepoint row): a funnel that
    # hands a name of the table on as the starter's own facet hands the starter's recorded
    # facets on unattenuated; and without the node check a stopgap name stands in front of
    # another node's process.
    Fault.new(name: "a funnel that hands on the starter's recorded facets", file: SERVICE,
              from: "attenuated(_Name, _Grant) ->\n    false.",
              to: "attenuated(_Name, Grant) ->\n    {true, Grant}.",
              tests: 'erx_domain_mints_srv_tests', caught_by: 'funnel'),
    Fault.new(name: 'a funnel that takes a process of another node for a stopgap name', file: SERVICE,
              from: 'node(Pid) =:= node() andalso {true, {Pid, Limits}}',
              to: 'is_pid(Pid) andalso {true, {Pid, Limits}}',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'stopgap_names'),
    # A session's template grant of a service the system domain serves, which the
    # service skips: the session finds no inspect facet in its ready answer.
    Fault.new(name: 'a template grant of a system service that the service skips', file: SERVICE,
              from: '<- Rows],',
              to: '<- Rows, false],',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'session_inspect'),
    # The grant check of a system domain's service (R3): a ready answer that takes every
    # grantee's grants, so a session whose template holds no start grant gets one.
    Fault.new(name: "a ready answer that ignores whose grant a system service's grant is", file: SERVICE,
              from: '<- Rows, T =:= Template].',
              to: '<- Rows, T >= 0, Template >= 0].',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'session_without_files_grant'),
    # A tree grant of a system domain's service bound to another domain than its
    # grantee: the grant exports itself to that domain, not to the session.
    Fault.new(name: 'a tree grant bound to another client', file: SERVICE,
              from: 'Binding = #{client => Id, ends_with => DomainPid, exports => Exports},',
              to: 'Binding = #{client => Id + 1, ends_with => DomainPid, exports => Exports},',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'session_files_grant'),
    # The boot's services list names the system domain's services with the server
    # `system`, which the mint core, keyed by configured rows, refuses with badarg so
    # that no such entry is ever kept there: this seed guards the filter and the
    # refusal as a pair (without the filter the domain service does not boot).
    Fault.new(name: "a mint core handed the system domain's services", file: SERVICE,
              from: '<- maps:get(services, Boot, []), Server =/= system],',
              to: '<- maps:get(services, Boot, [])],',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'session_files_grant'),
    # The session mark (docs/design-system.md, "Facets a configured domain serves"): a
    # server's end that drops the grants' marks, so its new incarnation's re-mint of the
    # display's session's grant carries none.
    Fault.new(name: 'a re-mint that drops the session mark', file: MINTS,
              from: %q{reconcile(State#{rows := Rows#{Row => {Id, ended}}})},
              to: %q{reconcile(State#{rows := Rows#{Row => {Id, ended}},
                                      grants := maps:map(fun(_, E) -> E#{mark := false} end, maps:get(grants, State))})},
              tests: 'erx_domain_mints_tests', caught_by: 'session_mark_test'),
    # A facet that drops a forward whose service ended without replying leaves the
    # grantee waiting out its own timeout, where an inspect worker OTP killed at its heap
    # limit must answer {error, failed}.
    Fault.new(name: 'a facet that drops a forward whose service ended',
              file: 'erlang/apps/erx/src/erx_facet.erl',
              from: 'loop(replied(Monitor, {error, failed}, State));',
              to: 'loop(State#{forwards := maps:remove(Monitor, Forwards)});',
              tests: 'erx_facet_tests', caught_by: 'a_forwards_service_that_ends_answers_failed_test'),
    # The check of a call from another domain that erx_facet and erx_session_line share
    # (erx:call_from/3): one that does not compare its reply alias's domain lets the
    # grantee have the facet's reply go to a third domain.
    Fault.new(name: "a call check that does not compare the reply alias's domain",
              file: 'erlang/apps/erx/src/erx.erl',
              from: 'Owner(Caller) =:= D andalso Owner(Alias) =:= D;', to: 'Owner(Caller) =:= D;',
              tests: 'erx_facet_tests', caught_by: 'admits_only_its_grantee_test'),
    # A request past the limit in flight answered as a malformed one: the grantee cannot
    # tell a full facet, which a retry may pass, from a request it must not repeat.
    Fault.new(name: 'a request past the limit in flight refused as badarg',
              file: 'erlang/apps/erx/src/erx_facet.erl',
              from: 'refuse(From, busy, State);', to: 'refuse(From, badarg, State);',
              tests: 'erx_facet_tests', caught_by: 'limits_its_forwards_test'),
    # A grant's operations (docs/design-time.md, "On Fiasco"): a facet that admits an
    # operation its grant does not list lets a holder of one operation call every other.
    Fault.new(name: 'a facet that admits an operation its grant does not list',
              file: 'erlang/apps/erx/src/erx_facet.erl',
              from: '                false -> eperm', to: '                false -> ok',
              tests: 'erx_facet_tests', caught_by: 'admits_only_its_grants_operations_test'),
    # A grant listing operations to a callback that cannot check them would admit them all.
    Fault.new(name: 'a facet started for operations no callback checks',
              file: 'erlang/apps/erx/src/erx_facet.erl',
              from: 'false -> {error, unchecked_operations}', to: 'false -> {ok, all}',
              tests: 'erx_facet_tests', caught_by: 'a_grant_s_operations_need_a_checking_callback_test'),
    # A system-served grant that loses its row's operations reaches the facet granting none
    # it can check, so a callback without operation/1 starts and admits every operation.
    Fault.new(name: 'a served grant that drops its operations', file: SERVICE,
              from: 'Checked#{operations => maps:get(operations, Limits, [])}', to: 'Checked',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'served_test'),
    # The system domain's namespace (docs/design-system.md, "A session takes the console"):
    # a wait answered before its files grant settles lets the start table read rc.conf
    # before the system domain's data grant is installed.
    Fault.new(name: "a wait for the system domain's namespace answered at once", file: SERVICE,
              from: '    case InPlace(system) of', to: '    case is_function(InPlace) of',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'system_namespace'),
    # One incarnation's grant (docs/design-pcie.md, "Facets"), the pure decision of
    # erx_domain_mints:system_grant/3: one matched by the service alone answers a wait for
    # one incarnation with another's installed facet; and without the idle case the wait
    # for an incarnation that provides no pcie is never answered.
    Fault.new(name: 'a grant wait matched by its service alone', file: MINTS,
              from: '#{Key := #{state := {installed, {Id, _}, Pid}}} ->',
              to: '#{Key := #{state := {installed, _Pair, Pid}}} ->',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'await_installed'),
    Fault.new(name: 'a grant wait without its idle case', file: MINTS,
              from: 'idle_grant(ready) -> {error, unprovided};', to: 'idle_grant(ready) -> wait;',
              tests: 'erx_domain_mints_srv_tests', caught_by: 'await_unprovided'),
    # The answer to `report` (docs/design-pcie.md, "Facets"): a lowering that keeps every
    # function with a layout, blind to the library's confirmed and latest state, leaves
    # each function of a report the intake refused whole at its setting.
    Fault.new(name: 'a lowering blind to the intake', file: File.join(APPLICATION, 'erx_devices_pci_core.erl'),
              from: '#{record := Record, confirmed := true, state := ready} <- Layouts},',
              to: '#{record := Record} <- Layouts},',
              tests: 'erx_devices_pci_core_tests',
              caught_by: 'a_report_refused_whole_lowers_every_function_of_its_bridge_test'),
    # A holder's end (docs/design-pcie.md, "The catalogue and gives"): one that sends its
    # lowering without writing it to the library leaves the library saying the function
    # still decodes or masters for a holder that is gone.
    Fault.new(name: "a holder's end blind to the library", file: File.join(APPLICATION, 'erx_devices_pci_core.erl'),
              from: '[{mode, Index, off} || {Index, _, _} <- Lowered] ++', to: '[] ++',
              tests: 'erx_devices_pci_core_tests',
              caught_by: 'a_holders_end_lowers_its_rows_in_the_library_then_sends_test'),
    # The PCIe process (docs/design-pcie.md, "Concurrency"): one that forgets a row once a
    # read no longer shows its holder, which the library clears at the end before it
    # reports it, sends no lowering, so the function goes on mastering for no holder.
    Fault.new(name: "a holder's rows forgotten before its end", file: File.join(APPLICATION, 'erx_devices_pci.erl'),
              from: 'end, Held,', to: 'end, maps:with([], Held),',
              tests: 'erx_devices_pci_tests',
              caught_by: 'a_holders_end_after_the_library_cleared_its_row_is_still_sent_test'),
    # One that answers a report before it writes answered leaves a restart blind to an
    # incarnation it answered.
    Fault.new(name: 'a report answered before answered is written', file: File.join(APPLICATION, 'erx_devices_pci.erl'),
              from: '%% Written before it is sent, so a restart never misses an answered incarnation.',
              to: 'gen_server:reply(From, {ok, erx_devices_pci_core:settings(Devices)}),',
              tests: 'erx_devices_pci_tests',
              caught_by: 'the_answered_incarnation_is_written_before_the_answer_test'),
    # One that restarts blind to answered sends no holder's lowering while the answered
    # incarnation lives.
    Fault.new(name: 'a restart blind to answered', file: File.join(APPLICATION, 'erx_devices_pci.erl'),
              from: 'resume(erx_devices_pci_core:resume(catalogues(Lib), Devices), Armed)',
              to: 'resume(between, Armed)',
              tests: 'erx_devices_pci_tests',
              caught_by: 'a_restart_while_the_answered_incarnation_lives_keeps_lowering_test'),
    # One that passes the enumerator's answer on unread hands a term of the PCIe domain's
    # to a holder.
    Fault.new(name: "an enumerator's answer passed on", file: File.join(APPLICATION, 'erx_devices_pci.erl'),
              from: 'pcie_answered(Then, interface(Answer), State)', to: 'pcie_answered(Then, Answer, State)',
              tests: 'erx_devices_pci_tests',
              caught_by: 'an_enumerator_answer_outside_the_interface_is_not_passed_on_test')
  ].freeze
  
  def test_the_cases_catch_each_seeded_fault
    FAULTS.each do |fault|
      source = File.read(File.join(ROOT, fault.file))
      assert_includes source, fault.from, fault.name
      output = eunit_output(fault.tests, deadline: 120, replaced: { fault.file => source.sub(fault.from, fault.to) })
      refute output.fetch(:passed), "#{fault.name} passed:\n#{output.fetch(:text)}"
      assert_match(/#{fault.caught_by}.*\*failed\*/m, output.fetch(:text), fault.name)
    end
  end

  private

  def assert_eunit_passes(mod, deadline:)
    output = eunit_output(mod, deadline: deadline)
    assert output.fetch(:passed), output.fetch(:text)
    assert_match(/[1-9][0-9]* tests passed/, output.fetch(:text))
  end

  # Compiles the applications and tests, with any source replaced, and runs the cases of
  # mod: whether they passed, and the run's text.
  def eunit_output(mod, deadline:, replaced: {})
    Dir.mktmpdir('erx-domain-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      output, status = Open3.capture2e('gtimeout', '-k', '10', deadline.to_s, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval',
                                       "halt(case eunit:test(#{mod}, [verbose]) of ok -> 0; _ -> 1 end).",
                                       chdir: work, stdin_data: '')
      { passed: status.success?, text: output }
    end
  end
end
