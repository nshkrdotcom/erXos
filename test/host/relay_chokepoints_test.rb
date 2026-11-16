# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The terminal relay's chokepoints (docs/design-shell.md, "The terminal relay's
# protocol", "Only erx_cmd's and the console's opens read"): only erx_cmd and
# erx_console call erx_session_relay:open_reader, only erx_session_relay,
# erx_output, erx_console and erx_log_h name erx_tty_owner, and only
# erx_session_relay builds the request for an open made for reading. The tree
# passes, and a program handler that opens for reading, by the client function or
# by a request it builds and sends by name or to a relay's pid, fails.
class RelayChokepointsTest < Minitest::Test
  include ChokepointsHelper

  RULES = %w[relay-readers relay-name relay-requests].freeze
  HANDLER = 'erlang/apps/erx_shell/src/erx_program_handler.erl'

  def found(files) = erlang_found(RULES, files)

  def test_the_tree_passes_and_the_relay_is_a_site
    files = erlang_tree
    assert_empty evaluate(RULES.map { |name| rule(name) }, files).map(&:to_s)
    assert_match rule('relay-name').pattern, files.fetch('erlang/apps/erx_session/src/erx_session_relay.erl')
  end

  def test_a_handler_that_calls_open_reader_fails
    text = "-module(erx_program_handler).\nopen(Relay, Job) -> erx_session_relay:open_reader(Relay, Job).\n"
    assert_equal [['relay-readers', HANDLER, 2]], found(HANDLER => text)
  end

  def test_a_handler_that_sends_the_open_by_name_fails
    text = "-module(erx_program_handler).\nopen(Job) ->\n    gen_server:call(erx_tty_owner, {open, Job, read}, infinity).\n"
    assert_equal [['relay-name', HANDLER, 3], ['relay-requests', HANDLER, 3]], found(HANDLER => text).sort
  end

  # A relay of a tty other than the domain's line holds no name, so the request
  # sent to its pid is caught by its shape; a write-only open is not, nor the
  # core's four-element request, which the relay refuses from a caller.
  def test_a_handler_that_sends_the_open_to_a_relays_pid_fails
    text = "-module(erx_program_handler).\nopen(Relay, Job) ->\n    gen_server:call(Relay, {open, Job, read}).\n" \
           "w(Relay, Job) -> gen_server:call(Relay, {open, Job, write}).\n" \
           "c(Relay, Job, O) -> gen_server:call(Relay, {open, Job, read, O}).\n"
    assert_equal [['relay-requests', HANDLER, 3]], found(HANDLER => text)
    assert_empty found('erlang/apps/erx_session/src/erx_session_relay.erl' => text)
  end

  def test_indirect_forms_fail
    text = "f(M, J) -> M:open_reader(J).\ng(J) -> apply(erx_session_relay, open_reader, [J]).\n" \
           "h() -> 'erx_tty_owner' ! x.\n-define(R, erx_session_relay).\n"
    assert_equal [['relay-readers', HANDLER, 1], ['relay-readers', HANDLER, 2], ['relay-name', HANDLER, 3],
                  ['relay-readers', HANDLER, 4]], found(HANDLER => text).sort_by { |_, _, line| line }
  end

  # The name in a string is a site, since list_to_atom/1 could make it the atom;
  # the function in a doc string is not.
  def test_the_name_in_a_string_fails_and_the_function_in_a_doc_string_passes
    text = "-moduledoc \"Opens through erx_session_relay:open_reader/1.\".\n" \
           "%% erx_tty_owner\nf(J) -> erx_session_relay:open_writer(J).\ng() -> list_to_atom(\"erx_tty_owner\").\n"
    assert_equal [['relay-name', HANDLER, 4]], found(HANDLER => text)
    assert_empty found('test/erlang/seeded_tests.erl' => "f(J) -> erx_session_relay:open_reader(J), erx_tty_owner.\n")
  end

  def test_the_readers_and_the_names_holders_are_sites
    call = "f(J) -> erx_session_relay:open_reader(J), erx_tty_owner.\n"
    assert_equal [%w[relay-name erlang/apps/erx_shell/src/erx_cmd.erl]],
                 found('erlang/apps/erx_shell/src/erx_cmd.erl' => call).map { |rule, path, _| [rule, path] }
    assert_empty found('erlang/apps/erx/src/erx_console.erl' => call)
    assert_empty found('otp/lib/kernel/src/erx_output.erl' => "f() -> erx_tty_owner.\n")
  end
end
