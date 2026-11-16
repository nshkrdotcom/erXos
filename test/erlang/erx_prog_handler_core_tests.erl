%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_core_tests).
-moduledoc """
erx_prog_handler_core, the handler's decisions: the descriptors are
reserved one at a time in order and the start follows; a refusal at any
step undoes exactly what was reserved; reports queue behind the start and
one is out at a time, an owed one waiting for room; a hand-off report is
installed before it is sent and a refused install becomes the pipe
server's install_failed; notices name the program; a kill or probe is
answered on its own slot, behind the frames already queued, and reaches
the program itself alone; a pipe installs both ends before its reply, and
a refused install closes both; a frame the grammar refuses stops the program
with SIGSYS; a stop is asked once;
and the exit status tells the starter and ends the handler. A bounded
exhaustive walk over every sequence of the running phase's events, a
pipe's request with each of its outcomes among them, checks that at most
one frame is ever out, that frames reach the program in the order they
were queued, that a pipe does exactly what its outcome asks, and that
nothing follows the end.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(PID, 21).
-define(HAND(N), {pipe_hand, N, {pipe, read, {9, N}, #{lock => {hand, 1}}}}).
-define(ASK(Slot, Request), {frame, {erx_prog, 1, Slot, Request}}).
-define(ANSWER(Slot, Reply), {send, {erx_prog, 1, Slot, Reply}}).
%% The status of a stop for a refused frame, 256 + SIGSYS, and of a SIGKILL.
-define(REFUSED, 268).
-define(KILLED, 265).
-define(TABLE, [#{point => [], provider => release, root => [], rights => ro}]).

new_refuses_bad_specs_test_() ->
    [?_assertEqual({error, einval}, new(1, [])),
     ?_assertEqual({error, einval}, new(?PID, [{0, {pipe, a}}, {0, {pipe, b}}])),
     ?_assertEqual({error, einval}, new(?PID, [{1024, {pipe, a}}])),
     ?_assertEqual({error, einval}, new(?PID, [{3, {buffer, 1, 4096}}, {4, {buffer, 1, 4096}}])),
     ?_assertEqual({error, einval}, new(?PID, [{3, {mem, 1, 1}}])),
     ?_assertMatch({ok, _, [holder]}, new(?PID, []))].

reserves_in_order_then_starts_test() ->
    {ok, C0, [holder]} = new(?PID, [{0, {pipe, r}}, {3, {buffer, 5, 8192}}, {1, {pipe, w}}]),
    {C1, [{inherit, r}]} = erx_prog_handler_core:step(C0, {holder, ok}),
    {C2, [{lend, 5, 8192}]} = erx_prog_handler_core:step(C1, {reserved, ?HAND(1)}),
    {C3, [{inherit, w}]} = erx_prog_handler_core:step(C2, {reserved, {mem, 77, 2, 4096}}),
    {C4, [{start, Fds}]} = erx_prog_handler_core:step(C3, {reserved, ?HAND(2)}),
    ?assertEqual([{0, ?HAND(1)}, {3, {mem, 77, 2}}, {1, ?HAND(2)}], Fds),
    {C5, [{answer, {ok, [{3, 4096}]}}]} = erx_prog_handler_core:step(C4, started),
    ?assertEqual(running, erx_prog_handler_core:phase(C5)).

refused_start_undoes_everything_test() ->
    {ok, C0, _} = new(?PID, [{0, {pipe, r}}, {3, {buffer, 5, 8192}}, {1, {pipe, w}}]),
    C3 = run(C0, [{holder, ok}, {reserved, ?HAND(1)}, {reserved, {mem, 77, 2, 4096}}, {reserved, ?HAND(2)}]),
    {C4, Actions} = erx_prog_handler_core:step(C3, {refused, enomem}),
    ?assertEqual([{hand_drop, 1}, {hand_drop, 2}, {unlend, 77}, holder_drop, {answer, {error, enomem}}],
                 Actions),
    ?assertEqual({ended, normal}, erx_prog_handler_core:phase(C4)).

refused_reservation_undoes_what_came_before_test_() ->
    {ok, C0, _} = new(?PID, [{0, {pipe, r}}, {1, {pipe, w}}]),
    C1 = run(C0, [{holder, ok}, {reserved, ?HAND(1)}]),
    {_, Actions} = erx_prog_handler_core:step(C1, {refused, ebadf}),
    {_, Refused} = erx_prog_handler_core:step(run(C0, []), {holder, {error, eexist}}),
    {_, NoMemory} = erx_prog_handler_core:step(run(C0, []), {holder, {error, enomem}}),
    [?_assertEqual([{hand_drop, 1}, holder_drop, {answer, {error, ebadf}}], Actions),
     %% Another handler's entry is not this handler's to drop.
     ?_assertEqual([{answer, {error, einval}}], Refused),
     ?_assertEqual([{answer, {error, enomem}}], NoMemory)].

reports_wait_for_the_start_test() ->
    {ok, C0, _} = new(?PID, [{0, {pipe, r}}]),
    C1 = run(C0, [{holder, ok}, {report, {pipe_lost, 9, 1}}, {reserved, ?HAND(1)}]),
    {_, Actions} = erx_prog_handler_core:step(C1, started),
    ?assertEqual([{answer, {ok, []}}, {send, {erx_prog, 1, {pipe_lost, 9, 1}}}], Actions).

owed_frame_waits_for_room_test() ->
    C0 = running(),
    {C1, [{send, F1}]} = erx_prog_handler_core:step(C0, {report, {pipe_lost, 9, 1}}),
    {C2, []} = erx_prog_handler_core:step(C1, {report, {pipe_lost, 9, 2}}),
    {C3, []} = erx_prog_handler_core:step(C2, {sent, busy}),
    {C4, []} = erx_prog_handler_core:step(C3, {report, {pipe_lost, 9, 3}}),
    {C5, [{send, F1}]} = erx_prog_handler_core:step(C4, room),
    {_, [{send, F2}]} = erx_prog_handler_core:step(C5, {sent, ok}),
    ?assertEqual({erx_prog, 1, {pipe_lost, 9, 2}}, F2).

hand_off_is_installed_then_sent_test_() ->
    Report = {pipe_reader, 9, 1, 2, {hand, 1}, open},
    C0 = running(),
    {C1, [{install, {pipe_hand, 4, Report}}]} = erx_prog_handler_core:step(C0, {report, {pipe_hand, 4, Report}}),
    {_, Sent} = erx_prog_handler_core:step(C1, {installed, {pipe_reader, 9, 1, 2, 500, open}}),
    {C2, Refused} = erx_prog_handler_core:step(C1, {install_refused, einval}),
    [?_assertEqual([{send, {erx_prog, 1, {pipe_reader, 9, 1, 2, 500, open}}}], Sent),
     ?_assertEqual([{forward, {install_failed, {program, ?PID}, 9, 1}}], Refused),
     ?_assertEqual(running, erx_prog_handler_core:phase(C2))].

notices_name_the_program_test_() ->
    C = running(),
    [?_assertEqual({C, [{forward, {closed, {program, ?PID}, 9, 1}}]},
                   erx_prog_handler_core:step(C, {frame, {erx_prog, 1, {closed, 9, 1}}})),
     ?_assertEqual({C, [{forward, {drained, {program, ?PID}, 9, 1, 3}}]},
                   erx_prog_handler_core:step(C, {frame, {erx_prog, 1, {drained, 9, 1, 3}}})),
     ?_assertMatch({_, [{stop, ?REFUSED}]}, erx_prog_handler_core:step(C, {frame, {erx_prog, 1, {closed, 0, 1}}}))].

%% The handler keeps no child record and its program holds no signal
%% right, so a program's kill and probe reach the program itself alone.
kill_of_itself_with_sigkill_stops_it_and_answers_ok_test() ->
    ?assertMatch({_, [{stop, ?KILLED}, ?ANSWER(3, ok)]},
                 erx_prog_handler_core:step(running(), ?ASK(3, {kill, ?PID, sigkill}))).

kill_beyond_reach_is_esrch_test_() ->
    [?_assertMatch({_, [?ANSWER(3, {error, esrch})]},
                   erx_prog_handler_core:step(running(), ?ASK(3, {kill, Target, Signal})))
     || Target <- [2, ?PID + 1, 16#7fffffff], Signal <- [sigterm, sigkill, sigstop]].

kill_of_itself_with_a_job_control_signal_is_eperm_test_() ->
    [?_assertMatch({_, [?ANSWER(0, {error, eperm})]},
                   erx_prog_handler_core:step(running(), ?ASK(0, {kill, ?PID, Signal})))
     || Signal <- [sigstop, sigtstp, sigttin, sigttou, sigcont]].

%% The protocol has no report that carries a signal to a program (TODO.md),
%% so a kill of itself with any other signal is refused, never ok.
kill_of_itself_with_another_signal_is_enosys_test() ->
    ?assertMatch({_, [?ANSWER(15, {error, enosys})]},
                 erx_prog_handler_core:step(running(), ?ASK(15, {kill, ?PID, sigterm}))).

%% Files: an open is relayed with the narrowed table and the working
%% directory, and its answer becomes the lowest free open; a read, a write
%% and a clunk go to the open's description; each answer comes back on the
%% request's own slot.
open_is_relayed_then_answered_with_an_open_test_() ->
    {C1, Relayed} = erx_prog_handler_core:step(running(), ?ASK(7, {file, lopen, <<"doom.wad">>, 0})),
    {C2, Answered} = erx_prog_handler_core:step(C1, {file_opened, 7, {ok, desc}}),
    {_, Second} = erx_prog_handler_core:step(sent(C2), ?ASK(8, {file, lcreate, <<"f">>, 1, 8#644})),
    [?_assertEqual([{open, 7, <<"doom.wad">>, 0, none, ?TABLE, [<<"data">>]}], Relayed),
     ?_assertEqual([?ANSWER(7, {ok, 0})], Answered),
     ?_assertEqual([{open, 8, <<"f">>, 1, 8#644, ?TABLE, [<<"data">>]}], Second)].

refused_open_answers_its_errno_test_() ->
    {C1, _} = erx_prog_handler_core:step(running(), ?ASK(7, {file, lopen, <<"x">>, 0})),
    [?_assertMatch({_, [?ANSWER(7, {error, enoent})]},
                   erx_prog_handler_core:step(C1, {file_opened, 7, {error, enoent}})),
     %% An error the protocol has no name for is eio.
     ?_assertMatch({_, [?ANSWER(7, {error, eio})]},
                   erx_prog_handler_core:step(C1, {file_opened, 7, {error, no_such_errno}}))].

unknown_open_flags_are_einval_test_() ->
    [?_assertMatch({_, [?ANSWER(7, {error, einval})]}, erx_prog_handler_core:step(running(), ?ASK(7, Request)))
     || Request <- [{file, lopen, <<"x">>, 16#40}, {file, lopen, <<"x">>, 3},
                    {file, lcreate, <<"x">>, 16#40000, 8#644},
                    {file, lcreate, <<"x">>, ?ERX_P9_O_EXCL bor ?ERX_P9_O_DIRECTORY, 8#644}]].

%% O_DIRECTORY and O_NOFOLLOW go to the resolution as the program sent them; an lcreate
%% with O_DIRECTORY, which creates nothing, goes as a lookup, and an lopen with O_EXCL
%% and O_DIRECTORY, whose O_EXCL means nothing without O_CREAT, goes too.
directory_and_nofollow_are_relayed_test_() ->
    Directory = ?ERX_P9_O_DIRECTORY,
    Both = ?ERX_P9_O_DIRECTORY bor ?ERX_P9_O_NOFOLLOW,
    Excl = ?ERX_P9_O_EXCL bor ?ERX_P9_O_DIRECTORY,
    [?_assertMatch({_, [{open, 7, <<"d">>, Flags, Mode, _, _}]},
                   erx_prog_handler_core:step(running(), ?ASK(7, Request)))
     || {Request, Flags, Mode} <- [{{file, lopen, <<"d">>, Both}, Both, none},
                                   {{file, lcreate, <<"d">>, ?ERX_P9_O_NOFOLLOW, 8#644}, ?ERX_P9_O_NOFOLLOW, 8#644},
                                   {{file, lcreate, <<"d">>, Directory, 8#644}, Directory, none},
                                   {{file, lopen, <<"d">>, Excl}, Excl, none}]].

opens_past_the_descriptor_bound_are_emfile_test() ->
    Full = lists:foldl(fun(N, C) -> opened(C, 7, N) end, running(), lists:seq(1, 1024)),
    ?assertMatch({_, [?ANSWER(7, {error, emfile})]},
                 erx_prog_handler_core:step(Full, ?ASK(7, {file, lopen, <<"x">>, 0}))).

read_copies_then_answers_its_count_test() ->
    C = opened(running(), 7, desc),
    {C1, Relayed} = erx_prog_handler_core:step(C, ?ASK(3, {file, read, 0, 4, 2})),
    {C2, Copy} = erx_prog_handler_core:step(C1, {file_done, 3, {ok, <<"wad!">>}}),
    {_, Answer} = erx_prog_handler_core:step(C2, {file_copied, 3, ok}),
    ?assertEqual([{read, desc, 3, 4}], Relayed),
    ?assertEqual([{copy_in, 3, 2, <<"wad!">>}], Copy),
    ?assertEqual([?ANSWER(3, {ok, 4})], Answer).

read_at_the_end_answers_zero_test() ->
    {C1, _} = erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, {file, read, 0, 4, 2})),
    ?assertEqual({ok, 0}, answer(erx_prog_handler_core:step(C1, {file_done, 3, eof}))).

%% A read's answer longer than its count is never copied.
read_longer_than_its_count_is_eio_test() ->
    {C1, _} = erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, {file, read, 0, 4, 2})),
    ?assertMatch({_, [?ANSWER(3, {error, eio})]},
                 erx_prog_handler_core:step(C1, {file_done, 3, {ok, <<"five!">>}})).

failed_copy_answers_its_errno_test() ->
    {C1, _} = erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, {file, read, 0, 4, 2})),
    {C2, _} = erx_prog_handler_core:step(C1, {file_done, 3, {ok, <<"ab">>}}),
    ?assertEqual({error, enosys}, answer(erx_prog_handler_core:step(C2, {file_copied, 3, {error, enosys}}))).

write_answers_its_count_test() ->
    {C1, Relayed} = erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, {file, write, 0, 9, 1})),
    ?assertEqual([{write, desc, 3, 1, 9}], Relayed),
    ?assertEqual({ok, 9}, answer(erx_prog_handler_core:step(C1, {file_done, 3, ok}))).

clunk_takes_the_open_out_at_once_test() ->
    {C1, Relayed} = erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, {file, clunk, 0})),
    {C2, Answer} = erx_prog_handler_core:step(C1, {file_done, 3, ok}),
    ?assertEqual([{clunk, desc, 3}], Relayed),
    ?assertEqual([?ANSWER(3, ok)], Answer),
    ?assertEqual({error, ebadf}, answer(erx_prog_handler_core:step(sent(C2), ?ASK(4, {file, read, 0, 1, 0})))).

unknown_open_is_ebadf_test_() ->
    [?_assertMatch({_, [?ANSWER(3, {error, ebadf})]},
                   erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, Request)))
     || Request <- [{file, read, 1, 4, 0}, {file, write, 1, 4, 0}, {file, clunk, 1}]].

%% The program was started with 4 slots: slot 4 is past them.
data_slot_past_the_program_slots_is_einval_test_() ->
    [?_assertMatch({_, [?ANSWER(3, {error, einval})]},
                   erx_prog_handler_core:step(opened(running(), 7, desc), ?ASK(3, Request)))
     || Request <- [{file, read, 0, 4, 4}, {file, write, 0, 4, 15}]].

%% A kill reaches the program while a file request waits.
kill_while_a_file_request_waits_test() ->
    {C1, _} = erx_prog_handler_core:step(running(), ?ASK(7, {file, lopen, <<"x">>, 0})),
    ?assertMatch({_, [{stop, ?KILLED}, ?ANSWER(3, ok)]},
                 erx_prog_handler_core:step(C1, ?ASK(3, {kill, ?PID, sigkill}))).

%% Narrowing: each path an entry of its own, rooted where the path lies on
%% the starter's deepest entry holding it, with its rights or read-only.
narrowing_test_() ->
    Table = [#{point => [], provider => release, root => [], rights => ro},
             #{point => [<<"data">>], provider => {grant, self(), <<"t">>}, root => [<<"r">>], rights => rw}],
    Narrow = fun(Within) -> files_of(erx_prog_handler_core:new(?PID, [], (files())#{table := Table, within := Within})) end,
    [?_assertEqual([#{point => [<<"data">>, <<"logs">>], provider => {grant, self(), <<"t">>},
                      root => [<<"r">>, <<"logs">>], rights => ro}],
                   Narrow([{<<"/data/logs">>, ro}])),
     ?_assertEqual([(lists:last(Table))#{point := [<<"data">>]}], Narrow([{<<"/data">>, rw}])),
     %% A mount below a narrowed path stays, read-only when that was asked.
     ?_assertEqual([#{point => [<<"data">>], provider => {grant, self(), <<"t">>}, root => [<<"r">>], rights => ro},
                    #{point => [<<"data">>, <<"logs">>], provider => {grant, self(), <<"l">>}, root => [], rights => ro}],
                   files_of(erx_prog_handler_core:new(?PID, [], (files())#{
                       table := Table ++ [#{point => [<<"data">>, <<"logs">>], provider => {grant, self(), <<"l">>},
                                            root => [], rights => rw}],
                       within := [{<<"/data">>, ro}]}))),
     ?_assertEqual({error, eacces}, Narrow([{<<"/bin">>, rw}])),
     ?_assertEqual({error, eacces}, Narrow([{<<"/data">>, rx}])),
     ?_assertEqual({error, einval}, Narrow([{<<"data">>, ro}])),
     ?_assertEqual({error, einval}, Narrow([{<<"/data/../etc">>, ro}])),
     ?_assertEqual({error, einval}, Narrow([{<<"/data">>, ro}, {<<"/data">>, ro}])),
     ?_assertEqual({error, enoent}, files_of(erx_prog_handler_core:new(?PID, [], (files())#{table := [], within := [{<<"/x">>, ro}]})))].

%% No display in a program's table (docs/design-files.md, "Narrowing for a
%% program"): a display's facet mounted at /n/display and a bind of its
%% client directory at /mnt/w, an alias that keeps the facet's provider,
%% pass to no program, whole or narrowed, while the data grant passes.
no_window_tree_test_() ->
    Data = #{point => [<<"data">>], provider => {grant, self(), <<"t">>}, root => [], rights => rw},
    Display = #{point => [<<"n">>, <<"display">>], provider => {facet, display, ?ERX_WINDOWS_TREE_BYTES},
                root => [], rights => rw},
    Alias = Display#{point := [<<"mnt">>, <<"w">>], root := [<<"client">>]},
    Granted = Display#{point := [<<"n">>, <<"d2">>], provider := {grant, self(), ?ERX_WINDOWS_TREE_BYTES}},
    Table = ?TABLE ++ [Data, Display, Alias, Granted],
    Narrow = fun(Within) -> files_of(erx_prog_handler_core:new(?PID, [], (files())#{table := Table, within := Within})) end,
    [?_assertEqual(?TABLE ++ [Data], Narrow(all)),
     ?_assertEqual([#{point => [<<"n">>], provider => release, root => [<<"n">>], rights => ro},
                    #{point => [<<"mnt">>], provider => release, root => [<<"mnt">>], rights => ro}],
                   Narrow([{<<"/n">>, ro}, {<<"/mnt">>, ro}])),
     %% A narrowing to a place on the window tree leaves no entry there.
     ?_assertEqual([], Narrow([{<<"/mnt/w/w1">>, rw}]))].

%% The names the export serves at /dev and /etc: a start whose table holds an
%% entry at or below one is refused, since the entry would hide the name or
%% put a mount beneath a file.
export_names_test_() ->
    Bind = fun(Point) -> #{point => Point, provider => {grant, self(), <<"t">>}, root => [], rights => rw} end,
    Start = fun(Entries, Within) ->
                    files_of(erx_prog_handler_core:new(?PID, [], (files())#{table := ?TABLE ++ Entries,
                                                                           within := Within}))
            end,
    [?_assertEqual({error, einval}, Start([Bind([<<"dev">>, <<"null">>])], all)),
     ?_assertEqual({error, einval}, Start([Bind([<<"dev">>, <<"tty">>, <<"x">>])], all)),
     ?_assertEqual({error, einval}, Start([Bind([<<"etc">>, <<"passwd">>])], all)),
     ?_assertEqual({error, einval}, Start([Bind([<<"dev">>, <<"tty">>, <<"x">>])], [{<<"/dev">>, ro}])),
     %% Beside the export's names, and at /dev itself, an entry stays.
     ?_assertMatch([_, _], Start([Bind([<<"dev">>, <<"draw">>])], all)),
     ?_assertMatch([_, _], Start([Bind([<<"dev">>])], all))].
%% A program's window (docs/design-files.md, "A program's window"): after the
%% holder entry and the descriptors, the window action; its /dev grant takes
%% the place of every entry at /dev; a window beside a buffer, an entry at or
%% below one of the window's names and a table with no room for /dev refuse.
window_test_() ->
    NewOn = fun(Entries, Fds, Display) ->
                    erx_prog_handler_core:new(?PID, Fds, (files())#{table := ?TABLE ++ Entries, window => Display})
            end,
    Bind = fun(Point) -> #{point => Point, provider => {grant, self(), <<"t">>}, root => [], rights => rw} end,
    Grant = list_to_pid("<0.4242.0>"),
    Dev = #{point => [<<"dev">>], provider => {grant, Grant, <<"export">>}, root => [<<"dev">>], rights => rw},
    New = fun(Entries, Fds) -> NewOn(Entries, Fds, display) end,
    Narrowed = fun(Within) ->
                       Table = ?TABLE ++ [Bind([<<"data">>]), Bind([<<"dev">>])],
                       erx_prog_handler_core:new(?PID, [], (files())#{table := Table, within => Within,
                                                                      window => display})
               end,
    {ok, C0, [holder]} = New([Bind([<<"data">>]), Bind([<<"dev">>]), Bind([<<"dev">>, <<"usb">>])], []),
    {C1, Window} = erx_prog_handler_core:step(C0, {holder, ok}),
    {C2, Start} = erx_prog_handler_core:step(C1, {windowed, Grant}),
    {_, [{open, _, _, _, _, Table, _}]} =
        erx_prog_handler_core:step(run(C2, [started]), ?ASK(7, {file, lopen, <<"x">>, 0})),
    {_, Refused} = erx_prog_handler_core:step(C1, {refused, enodev}),
    Full = [Bind([integer_to_binary(N)]) || N <- lists:seq(2, ?ERX_NS_MOUNTS_MAX)],
    [?_assertEqual([{window, display}], Window),
     %% A display may be named none: it still gets its window.
     ?_assertMatch({_, [{window, none}]},
                   erx_prog_handler_core:step(element(2, NewOn([], [], none)), {holder, ok})),
     ?_assertEqual([{start, []}], Start),
     ?_assertEqual(?TABLE ++ [Bind([<<"data">>]), Bind([<<"dev">>, <<"usb">>]), Dev], Table),
     ?_assertEqual([holder_drop, {answer, {error, enodev}}], Refused),
     ?_assertEqual({error, einval}, New([], [{3, {buffer, 1, 4096}}])),
     ?_assertEqual({error, einval}, New([Bind([<<"dev">>, <<"kbd">>, <<"x">>])], [])),
     ?_assertEqual({error, einval}, New([Bind([<<"dev">>, <<"clipboard">>])], [])),
     ?_assertMatch({ok, _, _}, erx_prog_handler_core:new(?PID, [], (files())#{table := ?TABLE ++ [Bind([<<"dev">>, <<"kbd">>, <<"x">>])]})),
     ?_assertEqual({error, einval}, New(Full, [])),
     ?_assertMatch({ok, _, _}, New(tl(Full) ++ [Bind([<<"dev">>])], [])),
     ?_assertEqual({error, einval}, erx_prog_handler_core:new(?PID, [], (files())#{window => "d"})),
     %% Rights only shrink: the window's /dev entry is rw and replaces the
     %% entries at /dev itself, so one that is read-only there, the starter's or
     %% left by a narrowing to /dev or to / read-only, refuses the start before
     %% anything is made. A table with no entry at /dev, as a session's is with
     %% its release slice read-only at / alone, leaves /dev to the export, which
     %% every program reaches, and starts; so does a narrowing away from /dev.
     ?_assertMatch({ok, _, [holder]}, New([], [])),
     ?_assertMatch({ok, _, [holder]}, New([Bind([<<"data">>])], [])),
     ?_assertMatch({ok, _, [holder]}, New([Bind([<<"dev">>])], [])),
     ?_assertEqual({error, eacces}, New([(Bind([<<"dev">>]))#{rights := ro}], [])),
     ?_assertEqual({error, eacces}, New([(Bind([<<"dev">>]))#{rights := rx}], [])),
     %% An entry on a window tree passes to no program, so it caps nothing; and
     %% an entry that hides one of the window's names refuses with einval first.
     ?_assertMatch({ok, _, [holder]},
                   New([(Bind([<<"dev">>]))#{provider := {grant, self(), ?ERX_WINDOWS_TREE_BYTES}, rights := ro}],
                       [])),
     ?_assertEqual({error, einval}, New([(Bind([<<"dev">>]))#{rights := ro}, Bind([<<"dev">>, <<"kbd">>])], [])),
     ?_assertEqual({error, eacces}, Narrowed([{<<"/dev">>, ro}])),
     ?_assertEqual({error, eacces}, Narrowed([{<<"/">>, ro}])),
     ?_assertMatch({ok, _, [holder]}, Narrowed([{<<"/data">>, rw}])),
     ?_assertMatch({ok, _, [holder]}, Narrowed([{<<"/dev">>, rw}]))].

probe_test_() ->
    [?_assertMatch({_, [?ANSWER(5, ok)]}, erx_prog_handler_core:step(running(), ?ASK(5, {probe, ?PID}))),
     ?_assertMatch({_, [?ANSWER(5, {error, esrch})]},
                   erx_prog_handler_core:step(running(), ?ASK(5, {probe, ?PID + 1})))].

replies_name_the_slot_of_their_request_test_() ->
    [?_assertMatch({_, [?ANSWER(Slot, ok)]}, erx_prog_handler_core:step(running(), ?ASK(Slot, {probe, ?PID})))
     || Slot <- lists:seq(0, 15)].

%% A pipe: the request asks the pipe server with the program's flags, the
%% read end's hand-off is installed, then the write end's, and the reply
%% names the values the installs gave.
-define(READ_HAND, {pipe_hand, 1, {pipe, read, {9, 1}, #{rix => 0, lock => {hand, 1}, wends => 1,
                                                      writers => [{1, {hand, 2}, {hand, 3}, 65536, {open, {hand, 4}}}],
                                                      readers => []}}}).
-define(WRITE_HAND, {pipe_hand, 2, {pipe, write, {9, 2}, #{wend => 1, ring => {hand, 1}, rpage => {hand, 2},
                                                        size => 65536, readers => [{0, {hand, 3}}]}}}).
-define(READ, {pipe, read, {9, 1}, #{rix => 0, lock => 101, wends => 1, writers => [{1, 102, 103, 65536, {open, 104}}],
                                     readers => []}}).
-define(WRITE, {pipe, write, {9, 2}, #{wend => 1, ring => 105, rpage => 106, size => 65536, readers => [{0, 107}]}}).

pipe_asks_the_pipe_server_with_the_programs_flags_test_() ->
    [?_assertMatch({_, [{make_pipe, Flags}]}, erx_prog_handler_core:step(running(), ?ASK(4, {pipe, Flags})))
     || Flags <- [[], [cloexec], [nonblock], [cloexec, nonblock]]].

pipe_installs_both_ends_then_replies_test() ->
    {C1, [{make_pipe, []}]} = erx_prog_handler_core:step(running(), ?ASK(4, {pipe, []})),
    {C2, Install1} = erx_prog_handler_core:step(C1, {pipe_made, {ok, ?READ_HAND, ?WRITE_HAND}}),
    {C3, Install2} = erx_prog_handler_core:step(C2, {end_installed, ?READ}),
    {_, Reply} = erx_prog_handler_core:step(C3, {end_installed, ?WRITE}),
    ?assertEqual([{install_end, ?READ_HAND}], Install1),
    ?assertEqual([{install_end, ?WRITE_HAND}], Install2),
    ?assertEqual([{send, {erx_prog, 1, 4, {ok, ?READ, ?WRITE}}}], Reply).

pipe_server_refusal_is_the_reply_test_() ->
    {C1, _} = erx_prog_handler_core:step(running(), ?ASK(4, {pipe, [cloexec]})),
    [?_assertMatch({_, [?ANSWER(4, {error, Errno})]}, erx_prog_handler_core:step(C1, {pipe_made, {error, Given}}))
     || {Given, Errno} <- [{enfile, enfile}, {enomem, enomem}, {ebadf, enomem}, {emfile, enomem}]].

%% An install the driver refuses undoes the whole pipe: the hand-off not yet
%% installed goes back, and the pipe server closes both ends, an installed
%% one's too, so nothing of the pipe holds the session's quota.
pipe_install_refused_first_closes_both_ends_test() ->
    C1 = run(running(), [?ASK(4, {pipe, []}), {pipe_made, {ok, ?READ_HAND, ?WRITE_HAND}}]),
    ?assertMatch({_, [{hand_drop, 1}, {hand_drop, 2}, {forward, {closed, {program, ?PID}, 9, 1}},
                      {forward, {closed, {program, ?PID}, 9, 2}}, ?ANSWER(4, {error, enomem})]},
                 erx_prog_handler_core:step(C1, {end_refused, einval})).

pipe_install_refused_second_closes_both_ends_test() ->
    C2 = run(running(), [?ASK(4, {pipe, []}), {pipe_made, {ok, ?READ_HAND, ?WRITE_HAND}}, {end_installed, ?READ}]),
    ?assertMatch({_, [{hand_drop, 2}, {forward, {closed, {program, ?PID}, 9, 1}},
                      {forward, {closed, {program, ?PID}, 9, 2}}, ?ANSWER(4, {error, enomem})]},
                 erx_prog_handler_core:step(C2, {end_refused, elimit})).

%% A reply queues behind the frame out, each on its own request's slot.
replies_queue_behind_the_frame_out_test() ->
    {C1, [{send, _}]} = erx_prog_handler_core:step(running(), {report, {pipe_lost, 9, 1}}),
    {C2, []} = erx_prog_handler_core:step(C1, ?ASK(7, {probe, ?PID + 1})),
    {C3, []} = erx_prog_handler_core:step(C2, ?ASK(2, {probe, ?PID})),
    {C4, [?ANSWER(7, {error, esrch})]} = erx_prog_handler_core:step(C3, {sent, ok}),
    ?assertMatch({_, [?ANSWER(2, ok)]}, erx_prog_handler_core:step(C4, {sent, ok})).

%% A frame the program's grammar refuses stops the program, as the driver
%% stops one for a malformed record, and the handler goes on.
refused_frames_stop_the_program_test_() ->
    [?_assertMatch({_, [{stop, ?REFUSED}]}, erx_prog_handler_core:step(running(), {frame, Frame}))
     || Frame <- [{erx_prog, 1, 0, anything}, {erx_prog, 1, 0, {kill, ?PID, 0}},
                  {erx_prog, 1, 0, {kill, 1, sigterm}}, {erx_prog, 1, 16, {probe, ?PID}},
                  {erx_prog, 2, 0, {probe, ?PID}}, {erx_prog, 1, 0, {probe, ?PID, extra}},
                  {erx_prog, 1, {closed, 9}}, {erx_start, 1, #{}}, <<"bytes">>, [], self()]].

refused_frames_after_a_stop_ask_nothing_more_test() ->
    {C1, [{stop, ?REFUSED}]} = erx_prog_handler_core:step(running(), {frame, {erx_prog, 1, 0, nope}}),
    ?assertMatch({_, []}, erx_prog_handler_core:step(C1, {frame, {erx_prog, 1, 0, nope}})),
    ?assertMatch({_, []}, erx_prog_handler_core:step(C1, stop)).

stop_once_then_exit_test() ->
    {C1, [{stop, 265}]} = erx_prog_handler_core:step(running(), stop),
    {C2, []} = erx_prog_handler_core:step(C1, stop),
    {C3, []} = erx_prog_handler_core:step(C2, {exit_status, 265}),
    ?assertEqual({ended, {shutdown, {program_exit, {signaled, sigkill}}}}, erx_prog_handler_core:phase(C3)),
    ?assertEqual({C3, []}, erx_prog_handler_core:step(C3, {report, {pipe_lost, 9, 1}})).

%% A program that exited before the stop reached it keeps its own status.
a_stop_behind_an_exit_keeps_its_status_test() ->
    {C1, [{stop, 265}]} = erx_prog_handler_core:step(running(), stop),
    {C2, []} = erx_prog_handler_core:step(C1, {exit_status, 3}),
    ?assertEqual({ended, {shutdown, {program_exit, {exited, 3}}}}, erx_prog_handler_core:phase(C2)).

a_port_closed_without_a_status_is_lost_test() ->
    {C1, []} = erx_prog_handler_core:step(running(), port_closed),
    ?assertEqual({ended, program_lost}, erx_prog_handler_core:phase(C1)).

refused_send_stops_the_program_test() ->
    {C1, [{send, _}]} = erx_prog_handler_core:step(running(), {report, {pipe_lost, 9, 1}}),
    {C2, []} = erx_prog_handler_core:step(C1, {report, {pipe_lost, 9, 2}}),
    {C3, Actions} = erx_prog_handler_core:step(C2, {sent, {error, enomem}}),
    ?assertEqual([{stop, 265}], Actions),
    %% Nothing queued behind the lost frame reaches the program.
    ?assertEqual({C3, []}, erx_prog_handler_core:step(C3, room)),
    %% Nor does a report that arrives after it, while the stop takes effect.
    ?assertMatch({_, []}, erx_prog_handler_core:step(C3, {report, {pipe_lost, 9, 3}})).

%% Every sequence of up to DEPTH running-phase events, the driver's answers
%% included wherever they may come, an open, its answer, a read of the
%% first open and the read's two answers, and a pipe's request.
-define(DEPTH, 6).

exhaustive_running_walk_test_() ->
    {timeout, 300, fun exhaustive_running_walk/0}.

exhaustive_running_walk() ->
    Count = walk(running(), #{out => none, queued => [], sent => [], next => 1, ended => false,
                              pending => #{}, opens => []}, ?DEPTH, 0),
    ?assert(Count > 10000).

walk(_C, _M, 0, Count) ->
    Count + 1;
walk(C, M, Depth, Count) ->
    lists:foldl(fun(Event, Acc) ->
                        {C1, Actions} = walk_step(C, Event),
                        M1 = check(Event, Actions, M),
                        walk(C1, M1, Depth - 1, Acc)
                end, Count + 1, events(M)).

%% The reports are numbered so the order they reach the program can be
%% checked; a probe of the program itself and a pipe's request queue their
%% replies among them.
events(#{next := N}) ->
    [{report, {pipe_lost, 9, N}}, {sent, ok}, {sent, busy}, room, stop, {exit_status, 0},
     {frame, {erx_prog, 1, {closed, 9, 1}}}, ?ASK(N rem 16, {probe, ?PID}),
     ?ASK(14, {file, lopen, <<"x">>, 0}), {file_opened, 14, {ok, desc}}, ?ASK(13, {file, read, 0, 4, 0}),
     {file_done, 13, {ok, <<"ab">>}}, {file_copied, 13, ok}
     | [{pipe_request, N rem 16, Outcome} || Outcome <- [installed, read_refused, write_refused, enfile]]].

%% The files of the model: an open waits on slot 14 and becomes the lowest
%% free open; a read of open 0 on slot 13 is ebadf until it exists, then
%% waits, is copied, and answers the copied count.
file_model(?ASK(14, {file, lopen, _, _}), #{pending := P} = M) ->
    M#{pending := P#{14 => open}};
file_model({file_opened, 14, {ok, _}}, #{pending := #{14 := open} = P, opens := Opens} = M) ->
    Open = hd([N || N <- lists:seq(0, 1023), not lists:member(N, Opens)]),
    M#{pending := maps:remove(14, P), opens := [Open | Opens],
       queued := maps:get(queued, M) ++ [{erx_prog, 1, 14, {ok, Open}}]};
file_model(?ASK(13, {file, read, 0, _, _}), #{pending := P, opens := Opens} = M) ->
    case lists:member(0, Opens) of
        true -> M#{pending := P#{13 => read}};
        false -> M#{queued := maps:get(queued, M) ++ [{erx_prog, 1, 13, {error, ebadf}}]}
    end;
file_model({file_done, 13, _}, #{pending := #{13 := read} = P} = M) ->
    M#{pending := P#{13 := copied}};
file_model({file_copied, 13, ok}, #{pending := #{13 := copied} = P} = M) ->
    M#{pending := maps:remove(13, P), queued := maps:get(queued, M) ++ [{erx_prog, 1, 13, {ok, 2}}]};
file_model(_Event, M) ->
    M.

%% A pipe's request is one event of the walk together with the effect
%% layer's answers to it, which come within the steps of that event: the
%% pipe made and both ends installed, made and the read end's install
%% refused, made and the write end's install refused, or refused by the
%% session's quota.
walk_step(C, {pipe_request, Slot, Outcome}) ->
    lists:foldl(fun(Event, {Ci, Actions}) ->
                        {Cj, More} = erx_prog_handler_core:step(Ci, Event),
                        {Cj, Actions ++ More}
                end, {C, []}, [?ASK(Slot, {pipe, []}) | pipe_answers(Outcome)]);
walk_step(C, Event) ->
    erx_prog_handler_core:step(C, Event).

pipe_answers(installed) -> [{pipe_made, {ok, ?READ_HAND, ?WRITE_HAND}}, {end_installed, ?READ}, {end_installed, ?WRITE}];
pipe_answers(read_refused) -> [{pipe_made, {ok, ?READ_HAND, ?WRITE_HAND}}, {end_refused, einval}];
pipe_answers(write_refused) -> [{pipe_made, {ok, ?READ_HAND, ?WRITE_HAND}}, {end_installed, ?READ}, {end_refused, elimit}];
pipe_answers(enfile) -> [{pipe_made, {error, enfile}}].

%% What a pipe's request does besides its reply, and the reply it queues. A
%% refusal drops the hand-offs not installed, numbered 1 and 2 in ?READ_HAND
%% and ?WRITE_HAND, and closes both ends, {9, 1} and {9, 2}.
pipe_effects(installed) -> [{make_pipe, []}, {install_end, ?READ_HAND}, {install_end, ?WRITE_HAND}];
pipe_effects(read_refused) ->
    [{make_pipe, []}, {install_end, ?READ_HAND}, {hand_drop, 1}, {hand_drop, 2},
     {forward, {closed, {program, ?PID}, 9, 1}}, {forward, {closed, {program, ?PID}, 9, 2}}];
pipe_effects(write_refused) ->
    [{make_pipe, []}, {install_end, ?READ_HAND}, {install_end, ?WRITE_HAND}, {hand_drop, 2},
     {forward, {closed, {program, ?PID}, 9, 1}}, {forward, {closed, {program, ?PID}, 9, 2}}];
pipe_effects(enfile) -> [{make_pipe, []}].

pipe_reply(installed) -> {ok, ?READ, ?WRITE};
pipe_reply(read_refused) -> {error, enomem};
pipe_reply(write_refused) -> {error, enomem};
pipe_reply(enfile) -> {error, enfile}.

%% The model: each report and each reply is queued; a send takes the oldest
%% unsent; at most one send is out; after the end nothing happens.
check(_Event, Actions, #{ended := true} = M) ->
    ?assertEqual([], Actions),
    M;
check(Event, Actions, M0) ->
    M1 = case {Event, maps:get(out, M0)} of
             {{report, {pipe_lost, _, N} = Report}, _} ->
                 M0#{queued := maps:get(queued, M0) ++ [{erx_prog, 1, Report}], next := N + 1};
             {?ASK(Slot, {probe, _}), _} -> M0#{queued := maps:get(queued, M0) ++ [{erx_prog, 1, Slot, ok}]};
             {?ASK(_, {file, _, _, _}), _} -> file_model(Event, M0);
             {?ASK(_, {file, _, _, _, _}), _} -> file_model(Event, M0);
             {{file_opened, _, _}, _} -> file_model(Event, M0);
             {{file_done, _, _}, _} -> file_model(Event, M0);
             {{file_copied, _, _}, _} -> file_model(Event, M0);
             {{pipe_request, Slot, Outcome}, _} ->
                 ?assertEqual(pipe_effects(Outcome), [Action || Action <- Actions, element(1, Action) =/= send]),
                 M0#{queued := maps:get(queued, M0) ++ [{erx_prog, 1, Slot, pipe_reply(Outcome)}]};
             {{sent, ok}, sending} ->
                 [_ | Rest] = maps:get(queued, M0),
                 M0#{out := none, queued := Rest};
             %% busy keeps the head owed; room lets the same head go again.
             {{sent, busy}, sending} -> M0#{out := owed};
             {room, owed} -> M0#{out := none};
             {{exit_status, _}, _} -> M0#{ended := true};
             _ -> M0
         end,
    lists:foldl(fun({send, Frame}, M) ->
                        ?assertEqual(none, maps:get(out, M)),
                        [Oldest | _] = maps:get(queued, M),
                        ?assertEqual(Oldest, Frame),
                        M#{out := sending, sent := maps:get(sent, M) ++ [Frame]};
                   (_, M) ->
                        M
                end, M1, Actions).

running() ->
    {ok, C0, _} = new(?PID, []),
    run(C0, [{holder, ok}, started]).

run(C, Events) ->
    lists:foldl(fun(E, Acc) -> element(1, erx_prog_handler_core:step(Acc, E)) end, C, Events).

%% A handler's core with the test's files: the whole table, from /data, 4 slots.
new(Pid, Fds) ->
    erx_prog_handler_core:new(Pid, Fds, files()).

files() ->
    #{table => ?TABLE, within => all, cwd => <<"/data">>, slots => 4}.

%% The narrowed table a core holds, read from the open it relays.
files_of({ok, C0, _}) ->
    {_, [{open, _, _, _, _, Table, _}]} =
        erx_prog_handler_core:step(run(C0, [{holder, ok}, started]), ?ASK(7, {file, lopen, <<"x">>, 0})),
    Table;
files_of({error, _} = Refused) ->
    Refused.

%% C with one more open, whose description is Desc, its answer sent.
opened(C, Slot, Desc) ->
    {C1, _} = erx_prog_handler_core:step(C, ?ASK(Slot, {file, lopen, <<"x">>, 0})),
    {C2, [?ANSWER(Slot, {ok, _})]} = erx_prog_handler_core:step(C1, {file_opened, Slot, {ok, Desc}}),
    sent(C2).

%% C once the frame out was taken.
sent(C) ->
    element(1, erx_prog_handler_core:step(C, {sent, ok})).

%% The reply a step sent.
answer({_, [{send, {erx_prog, 1, _Slot, Reply}}]}) ->
    Reply.
