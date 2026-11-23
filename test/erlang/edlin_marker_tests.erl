%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the line editor's handling of the receive overrun marker, a NUL a console
%% UART's driver puts where input was lost (erlang/apps/erx_uart/src/erx_mini_uart.erl):
%% edlin keeps it in the line, where prim_tty shows it as ^@, and no line that holds it is
%% finished, whether by Enter, by the end of input or by an accepted history search. Enter
%% rings the bell and holds the line: every later line of input is dropped, with the bell
%% once per line, until the user edits the line. The end of input drops the line and ends
%% the read (edits 80 and 81 of docs/design-runtime.md). The group cases run a group over
%% a driver the test plays. test/host/edlin_marker_test.rb runs them against the tree's
%% edlin, edlin_key and group.

-module(edlin_marker_tests).
-include_lib("eunit/include/eunit.hrl").

%% The marker stays in the line where it came, and the bytes after it are edited as usual.
marker_is_kept_in_the_line_test() ->
    {more_chars, Cont, Requests} = typed("rm -rf /" ++ [0] ++ "x"),
    ?assertEqual("rm -rf /" ++ [0] ++ "x", edlin:current_chars(Cont)),
    ?assert(lists:member({insert_chars, unicode, [0]}, Requests)).

%% Enter on a line that holds the marker rings the bell and does not finish the line.
enter_on_a_marked_line_rings_the_bell_test() ->
    {more_chars, Cont, Requests} = typed("rm -rf /" ++ [0] ++ "x\r"),
    ?assertEqual("rm -rf /" ++ [0] ++ "x", edlin:current_chars(Cont)),
    ?assert(lists:member(beep, Requests)).

%% The marker anywhere in a line of several, before the cursor or after it, holds the line.
marker_on_an_earlier_line_or_after_the_cursor_holds_the_line_test() ->
    {more_chars, Earlier, _} = typed([0] ++ "a\e\rb\r"),
    ?assertEqual([0] ++ "a\nb", edlin:current_chars(Earlier)),
    {more_chars, After, _} = typed("ab" ++ [0] ++ "\^A\r"),
    ?assertEqual("ab" ++ [0], edlin:current_chars(After)).

%% A refused Enter drops the rest of the input delivered with it, the remainder of the
%% damaged paste, so none of it joins the held line to run once the marker is deleted.
a_refused_enter_drops_the_rest_of_the_input_test() ->
    {more_chars, Cont, _} = typed("a" ++ [0] ++ "b\rls\r"),
    ?assertEqual("a" ++ [0] ++ "b", edlin:current_chars(Cont)).

%% A held line drops each later line of input through its newline, a line cut by the end
%% of a delivery included, and rings the bell once per line: the rest of a damaged paste
%% that arrives in later deliveries never joins the held line. Tab and a key bound to
%% nothing (F12) are part of a dropped line.
a_held_line_drops_later_lines_test() ->
    {more_chars, Held, _} = typed("cd /tm" ++ [0] ++ "x\nrm -"),
    {more_chars, Cont, Requests} = edlin:edit_line("rf\t*\e[24~\npwd\n", Held),
    ?assertEqual("cd /tm" ++ [0] ++ "x", edlin:current_chars(Cont)),
    ?assertEqual([beep, beep], [R || R <- Requests, R =:= beep]).

%% A key bound to an edit ends the hold and is read as usual, and input after it reaches
%% the line again; text before it is dropped.
an_editing_key_ends_the_hold_test() ->
    {more_chars, Held, _} = typed("a" ++ [0] ++ "b\r"),
    {more_chars, Cont, _} = edlin:edit_line("x\dc", Held),
    ?assertEqual("a" ++ [0] ++ "c", edlin:current_chars(Cont)).

%% The end of input on a marked line, held or not, drops the line and hands the end of
%% input on, so the read ends rather than waiting for an end the console sends only once.
end_of_input_drops_a_marked_line_test_() ->
    [?_test(begin
                {more_chars, Cont, _} = typed(Typed),
                {done, Line, eof, Requests} = edlin:edit_line(eof, Cont),
                ?assertEqual("", edlin:current_line(Line)),
                ?assert(lists:member(beep, Requests))
            end) || Typed <- ["ls" ++ [0], "ls" ++ [0] ++ "\r"]].

%% An accepted history search's line, which group hands back, is finished by the same
%% check: a marked one is held, an unmarked one finishes with the input after it.
an_accepted_search_is_finished_by_the_same_check_test() ->
    edlin:init(),
    MarkedLine = {[], {lists:reverse("rm" ++ [0]), []}, []},
    Marked = {line, "> ", MarkedLine, {normal, none}},
    ?assertMatch({more_chars, {line, "> ", MarkedLine, {held, none}}, [beep]},
                 edlin:finish_line(Marked, [])),
    Clean = {line, "> ", {[], {lists:reverse("ls"), []}, []}, {normal, none}},
    {done, Line, "\n", []} = edlin:finish_line(Clean, []),
    ?assertEqual("ls", edlin:current_line(Line)).

%% Once the marker is deleted, Enter finishes the line as usual.
deleting_the_marker_lets_enter_finish_the_line_test() ->
    {done, Line, [], _} = typed("ls" ++ [0] ++ "\d\r"),
    ?assertEqual("ls\n", edlin:current_line(Line)).

%% A line without the marker finishes on Enter, as on stock.
an_unmarked_line_finishes_test() ->
    {done, Line, [], _} = typed("ls\r"),
    ?assertEqual("ls\n", edlin:current_line(Line)).

%% A marker anywhere in an escape sequence ends the sequence and enters the line: after
%% ESC, after ESC [, and after a digit or a semicolon of a CSI sequence, where stock
%% crashes or swallows it.
a_marker_in_an_escape_sequence_enters_the_line_test_() ->
    [?_assertEqual([0] ++ "x", edlin:current_chars(element(2, typed(Prefix ++ [0] ++ "x"))))
     || Prefix <- ["\e", "\e[", "\e[1", "\e[1;"]].

%% A sequence cut by the end of a delivery and continued by a marker in the next.
a_marker_after_a_cut_sequence_enters_the_line_test() ->
    {more_chars, Cut, _} = typed("\e["),
    {more_chars, Cont, _} = edlin:edit_line([0] ++ "x", Cut),
    ?assertEqual([0] ++ "x", edlin:current_chars(Cont)).

%% A character that cannot continue a CSI sequence ends it and is read again, where stock
%% has no clause for it.
a_control_character_ends_a_csi_sequence_test() ->
    {done, Line, [], _} = typed("ls\e[1\r"),
    ?assertEqual("ls\n", edlin:current_line(Line)).

%% A search term that holds the marker matches no history line, so Enter in search mode
%% cannot run a line the damaged term happened to find.
marker_joins_a_search_term_test() ->
    edlin:init(),
    Search = {line, "search: ", {[], {[], []}, []}, {search, none}},
    {more_chars, Cont, _} = edlin:edit_line("rm" ++ [0], Search),
    ?assertMatch({line, _, _, {search, none}}, Cont),
    ?assertEqual("rm" ++ [0], edlin:current_chars(Cont)).

%% Through a group: a paste whose first line lost bytes rings the bell, its remainder is
%% dropped, and the held line runs once the user deletes the marker (Ctrl-B, then DEL).
a_group_runs_the_mended_line_only_test() ->
    with_group(fun(Group, Driver) ->
        ?assertEqual("ab\n", line(Group, Driver, ["a" ++ [0] ++ "b\rls\r", "\^B\d\r"])),
        ?assert(rang())
    end).

%% Through a group: a paste whose first line lost bytes, delivered in pieces, runs nothing
%% of its later lines; the user's edit of the held line runs only what the user mended.
a_group_runs_no_later_line_of_a_split_paste_test() ->
    with_group(fun(Group, Driver) ->
        ?assertEqual("cd /tmx\n",
                     line(Group, Driver, ["cd /tm" ++ [0] ++ "x\nrm -", "rf *\n", "\^B\d\r"]))
    end).

%% Through a group: the end of input on a held line ends the read.
a_group_ends_the_read_at_the_end_of_input_on_a_held_line_test() ->
    with_group(fun(Group, Driver) ->
        ?assertEqual(eof, line(Group, Driver, ["ls" ++ [0] ++ "\r", eof]))
    end).

%% Through a group: a marked line left by Up is not kept in the history, so a search that
%% only it would match finds nothing and Enter runs an empty line, not the marked one.
a_group_keeps_no_marked_line_in_its_history_test() ->
    with_group(fun(Group, Driver) ->
        ?assertEqual("ls\n", line(Group, Driver, ["ls\r"])),
        ?assertEqual("\n", line(Group, Driver, ["rm " ++ [0] ++ "y\e[A", "\^Rrm", "\r"]))
    end).

%% A key cut after two CSI digits by the end of a delivery (an F5 key, ESC [ 1 5 ~) waits
%% for the rest, where stock's parser answers a shape the editor has no clause for and the
%% group crashes.
a_key_cut_after_two_csi_digits_waits_for_the_rest_test() ->
    {more_chars, Cut, _} = typed("ls\e[15"),
    {more_chars, Cont, _} = edlin:edit_line("~", Cut),
    ?assertEqual("ls", edlin:current_chars(Cont)).

%% What the editor makes of Chars typed at a fresh prompt.
typed(Chars) ->
    edlin:init(),
    {more_chars, Start, _} = edlin:start("> "),
    edlin:edit_line(Chars, Start).

%% Runs Fun with a group in line-editing mode over a driver the test plays.
with_group(Fun) ->
    Test = self(),
    Driver = spawn_link(fun() -> driver(Test) end),
    Group = group:start(Driver, noshell, [{dumb, false}]),
    try
        Fun(Group, Driver)
    after
        [begin unlink(Pid), exit(Pid, kill) end || Pid <- [Group, Driver]]
    end.

%% The line a get_line answers once the driver has delivered Chunks, one per ask, a chunk
%% eof as the end of input, or none if no line comes within a second.
line(Group, Driver, Chunks) ->
    Test = self(),
    Reader = spawn_link(fun() -> Test ! {line, io:get_line(Group, "> ")} end),
    lists:foreach(fun(Chunk) ->
                          Ref = receive {asked, R} -> R after 5000 -> error(no_ask) end,
                          Group ! case Chunk of
                                      eof -> {Driver, eof};
                                      _ -> {Driver, {read, Ref, Chunk}}
                                  end
                  end, Chunks),
    receive
        {line, Line} -> Line
    after 1000 ->
        unlink(Reader),
        exit(Reader, kill),
        none
    end.

%% Whether the driver was asked to ring the bell.
rang() ->
    receive beep -> true after 0 -> false end.

%% The group's driver: each ask for input and each bell, to the test.
driver(Test) ->
    receive
        {_Group, read, Ref} -> Test ! {asked, Ref};
        {_Group, beep} -> Test ! beep;
        {_Group, {requests, Requests}} -> [Test ! beep || beep <- Requests];
        _Output -> ok
    end,
    driver(Test).
