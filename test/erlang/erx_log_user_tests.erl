%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The `user` of a session with no terminal (erx_log_user): what is written to it
%% becomes one notice record per line, sent where the domain's records go. Each case
%% takes the records in place of the log service, registered as erx_syslog, which is
%% where erx_log_h:write/1 sends a record first.
-module(erx_log_user_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(MAX, ?ERX_LOG_WRITE_TEXT_MAX).

%% Runs Case with the session's line started as a session with no console facet
%% starts it (erx_session_sup:line/1), the records taken by this process. The
%% emulator's own `user` gives up the name for the case and takes it back after.
with_user(Case) ->
    Stock = whereis(user),
    true = unregister(user),
    #{start := {Module, Function, Args}} = erx_session_sup:line(undefined),
    true = register(erx_syslog, self()),
    process_flag(trap_exit, true),
    {ok, User} = apply(Module, Function, Args),
    try
        Case(User)
    after
        unlink(User),
        exit(User, kill),
        unregister(erx_syslog),
        await_unregistered(user),
        true = register(user, Stock)
    end.

await_unregistered(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _Ending -> timer:sleep(10), await_unregistered(Name)
    end.

%% The records that arrive within a short wait, oldest first.
records() ->
    receive {log, Level, Text} -> [{Level, Text} | records()]
    after 100 -> []
    end.

%% The regression: in a session with no terminal, what an app writes to standard
%% output reaches the log, one notice record per line, its text as it was written.
a_session_with_no_terminal_logs_its_output_test() ->
    with_user(fun(_User) ->
        ok = io:format(user, "hello ~s~nsecond line~n", ["app"]),
        ?assertEqual([{notice, <<"hello app">>}, {notice, <<"second line">>}], records())
    end).

%% A session with a console facet keeps its console tty, which holds `user` itself.
a_session_with_a_console_keeps_its_tty_test() ->
    ?assertMatch(#{id := erx_session_tty}, erx_session_sup:line(self())).

%% A line written in two parts is one record, sent once its newline comes.
a_line_split_across_two_writes_is_one_record_test() ->
    with_user(fun(_User) ->
        ok = io:put_chars(user, "par"),
        ?assertEqual([], records()),
        ok = io:put_chars(user, "tial\n"),
        ?assertEqual([{notice, <<"partial">>}], records())
    end).

%% Empty lines make no record: Elixir's formatter writes a newline before and after
%% each of its lines, which would otherwise arrive as empty records or newlines.
empty_lines_make_no_record_test() ->
    ?assertEqual({[<<"05:10:22.437 [notice] hi">>], <<>>},
                 erx_log_user:lines(<<>>, <<"\n05:10:22.437 [notice] hi\n\n\n">>)).

%% A line longer than a record's text is sent in pieces of at most ?MAX bytes.
an_over_long_line_is_sent_in_pieces_test() ->
    Line = binary:copy(<<"a">>, 2 * ?MAX + 10),
    {Pieces, Held} = erx_log_user:lines(<<>>, <<Line/binary, "\n">>),
    ?assertEqual([?MAX, ?MAX, 10], [byte_size(Piece) || Piece <- Pieces]),
    ?assertEqual(<<>>, Held).

%% A line not yet ended is held only up to ?MAX bytes: what is past them is sent.
an_unended_line_is_held_within_bounds_test() ->
    {Pieces, Held} = erx_log_user:lines(<<>>, binary:copy(<<"a">>, 2 * ?MAX + 5)),
    ?assertEqual([?MAX, ?MAX], [byte_size(Piece) || Piece <- Pieces]),
    ?assertEqual(5, byte_size(Held)).

%% A piece ends at a character's end: a two-byte character across the bound goes
%% whole into the next piece, and every piece is UTF-8.
a_piece_never_splits_a_character_test() ->
    Head = binary:copy(<<"a">>, ?MAX - 1),
    {Pieces, <<>>} = erx_log_user:lines(<<>>, <<Head/binary, "\x{e9}tail\n"/utf8>>),
    ?assertEqual([Head, <<"\x{e9}tail"/utf8>>], Pieces).

%% Bytes that are no UTF-8, a run of continuation bytes, are cut at ?MAX itself, so
%% the split ends.
a_run_of_continuation_bytes_is_cut_at_the_bound_test() ->
    {Pieces, <<>>} = erx_log_user:lines(<<>>, <<(binary:copy(<<16#80>>, ?MAX + 1))/binary, "\n">>),
    ?assertEqual([?MAX, 1], [byte_size(Piece) || Piece <- Pieces]).

%% Reading is refused at once with an error, never left waiting: the session has no
%% input.
a_read_is_refused_with_an_error_test() ->
    with_user(fun(_User) ->
        ?assertEqual({error, enotsup}, io:get_chars(user, "", 1)),
        ?assertEqual({error, enotsup}, io:get_line(user, "")),
        ?assertEqual({error, enotsup}, io:columns(user))
    end).

%% The text is the program's own: control bytes reach the record unchanged, and the
%% log service's line, which shows it, escapes them, tab included.
the_text_is_raw_and_the_sink_escapes_it_test() ->
    with_user(fun(_User) ->
        ok = io:put_chars(user, "tab\there \e[31mred\n"),
        [{notice, Text}] = records(),
        ?assertEqual(<<"tab\there \e[31mred">>, Text),
        Line = erx_syslog_core:line(0, 4, 1, <<"app">>, {notice, Text}),
        ?assertEqual(nomatch, re:run(Line, "[\\x00-\\x1f\\x7f]"))
    end).

%% A line held when the server stops is sent as it stops.
a_held_line_is_sent_at_the_stop_test() ->
    with_user(fun(User) ->
        ok = io:put_chars(user, "no newline"),
        ok = gen_server:stop(User),
        ?assertEqual([{notice, <<"no newline">>}], records())
    end).
