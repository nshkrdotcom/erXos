%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The line tree and its keeper (docs/design-bluetooth.md, "The controller's line";
%% docs/design-files.md, "Waiting requests"): erx_line_fs served by a real erx_fs grant,
%% over erx_line, whose driver is a model the test drives. Each wait the cases assert on
%% has a deadline of 1 s.
-module(erx_line_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(NOFID, 16#ffffffff).
-define(O_RDONLY, 0).
-define(O_WRONLY, 1).
-define(O_RDWR, 2).

%% Fixtures --------------------------------------------------------------

%% A line and a grant of its tree, with fid 1 at the root, fids 2 and 3 opened on data
%% for reading and for writing, fid 4 on ctl and fid 5 on the root for reading. The
%% model driver reports itself to the test as {driver, Pid} at each start.
line() ->
    Test = self(),
    {ok, Line} = erx_line:start_link(fun(L) -> {ok, spawn_link(fun() -> driver(L, Test) end)} end),
    unlink(Line),
    Driver = driver_started(),
    {ok, Grant} = erx_fs:start_link(erx_line_fs, Line, rw),
    unlink(Grant),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_LINE_TREE_BYTES, 0}),
    {ok, _} = call(Grant, {walk, 1, 2, [<<"data">>]}),
    {ok, _} = call(Grant, {walk, 1, 3, [<<"data">>]}),
    {ok, _} = call(Grant, {walk, 1, 4, [<<"ctl">>]}),
    {ok, _} = call(Grant, {walk, 1, 5, []}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_WRONLY}),
    {ok, _, _} = call(Grant, {lopen, 4, ?O_WRONLY}),
    {ok, _, _} = call(Grant, {lopen, 5, ?O_RDONLY}),
    #{line => Line, grant => Grant, driver => Driver}.

stop(#{line := Line, grant := Grant}) ->
    exit(Grant, kill),
    exit(Line, kill).

%% The model driver: what the line sends it goes to the test, and the test makes it
%% deliver input or answer a write. It tells the test once it has handed input to the
%% line, so a case that needs the bytes in the line before its next request waits for
%% that (input/2); a request through the grant would otherwise race the driver's send.
driver(Line, Test) ->
    Test ! {driver, self()},
    driver_loop(Line, Test).

driver_loop(Line, Test) ->
    receive
        {erx_console_output, Ref, Bytes} -> Test ! {output, self(), Ref, Bytes};
        {input, Bytes} -> Line ! {erx_console_input, Bytes}, Test ! {delivered, self()};
        {written, Ref} -> Line ! {erx_console_written, Ref}
    end,
    driver_loop(Line, Test).

%% Hands Bytes to the line through Driver and returns once Driver has sent them.
input(Driver, Bytes) ->
    Driver ! {input, Bytes},
    receive {delivered, Driver} -> ok after 1000 -> erlang:error(not_delivered) end.

driver_started() ->
    receive {driver, Driver} -> Driver after 1000 -> erlang:error(no_driver) end.

%% What the driver was handed to write, as {Ref, Bytes}, within 1 s, or none.
output(Driver, Timeout) ->
    receive {output, Driver, Ref, Bytes} -> {Ref, Bytes} after Timeout -> none end.

call(Grant, Request) ->
    Alias = send(Grant, Request),
    case reply_within(Alias, 1000) of
        none -> erlang:error({no_reply, Request});
        Reply -> Reply
    end.

send(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    Alias.

reply_within(Alias, Timeout) ->
    receive {erx_9p, Alias, Reply} -> Reply after Timeout -> none end.

%% Waiting reads -----------------------------------------------------------

%% The regression: a read of data that waits for the controller holds up no write of
%% data, no read of another file and no clunk of another fid; the controller's bytes
%% then answer it, once.
a_waiting_read_blocks_no_other_request_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Write = send(Grant, {write, 3, 0, <<"cmd">>}),
    ?assertMatch({_, <<"cmd">>}, output(Driver, 1000)),
    ?assertMatch({ok, _}, call(Grant, {readdir, 5, 0, 4096})),
    ?assertEqual(ok, call(Grant, {clunk, 5})),
    ?assertEqual(none, reply_within(Read, 0)),
    ?assertEqual(none, reply_within(Write, 0)),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, reply_within(Read, 1000)),
    ?assertEqual(none, reply_within(Read, 100)),
    stop(Line).

%% A write is answered with its count once the driver has written it, not before.
a_write_is_answered_once_the_driver_wrote_it_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Write = send(Grant, {write, 3, 7, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Driver, 1000),
    ?assertEqual(none, reply_within(Write, 100)),
    Driver ! {written, Ref},
    ?assertEqual({ok, 3, 7}, reply_within(Write, 1000)),
    stop(Line).

%% Writes reach the driver one at a time, in order.
writes_reach_the_driver_one_at_a_time_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    First = send(Grant, {write, 3, 0, <<"a">>}),
    Second = send(Grant, {write, 3, 0, <<"b">>}),
    {Ref, <<"a">>} = output(Driver, 1000),
    ?assertEqual(none, output(Driver, 100)),
    Driver ! {written, Ref},
    ?assertEqual({ok, 1, 0}, reply_within(First, 1000)),
    {Ref2, <<"b">>} = output(Driver, 1000),
    Driver ! {written, Ref2},
    ?assertEqual({ok, 1, 0}, reply_within(Second, 1000)),
    stop(Line).

%% Buffered bytes answer a read at once, at most its count; the rest waits for the
%% next read, and waiting reads take bytes in the order they arrived.
reads_take_buffered_bytes_in_order_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    {ok, _} = call(Grant, {walk, 1, 6, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 6, ?O_RDONLY}),
    First = send(Grant, {read, 2, 0, 2}),
    Second = send(Grant, {read, 6, 0, 16}),
    Driver ! {input, <<"abcde">>},
    ?assertEqual({ok, <<"ab">>}, reply_within(First, 1000)),
    ?assertEqual({ok, <<"cde">>}, reply_within(Second, 1000)),
    Driver ! {input, <<"xyz">>},
    ?assertEqual({ok, <<"x">>}, call(Grant, {read, 2, 0, 1})),
    ?assertEqual({ok, <<"yz">>}, call(Grant, {read, 6, 0, 16})),
    stop(Line).

%% A flush of a waiting read answers it eintr, then the flush; the bytes that come
%% later go to the next reader.
a_flush_answers_a_waiting_read_eintr_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Flush = send(Grant, {flush, Read}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Flush, 1000)),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% A clunk of the reading fid answers its waiting read eintr, then the clunk, and
%% takes no byte the next reader should have.
a_clunk_settles_a_waiting_read_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Clunk = send(Grant, {clunk, 2}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Clunk, 1000)),
    {ok, _} = call(Grant, {walk, 1, 2, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% The keeper's end answers every request it held eio, a waiting read and a write the
%% driver holds, and the grant goes on serving.
the_keepers_end_answers_its_requests_eio_test() ->
    #{grant := Grant, line := Keeper, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Write = send(Grant, {write, 3, 0, <<"cmd">>}),
    {_, <<"cmd">>} = output(Driver, 1000),
    exit(Keeper, kill),
    ?assertEqual({error, eio}, reply_within(Read, 1000)),
    ?assertEqual({error, eio}, reply_within(Write, 1000)),
    ?assertMatch({ok, _}, call(Grant, {readdir, 5, 0, 4096})),
    stop(Line).

%% Resets ------------------------------------------------------------------

%% A reset ends the driver, which answers the write it held and the waiting read eio,
%% drops what was buffered and starts the driver afresh, then answers; a write sent
%% during the reset waits for it and goes to the new driver.
a_reset_ends_the_driver_and_starts_it_afresh_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Held = send(Grant, {write, 3, 0, <<"stuck">>}),
    {_, <<"stuck">>} = output(Driver, 1000),
    Read = send(Grant, {read, 2, 0, 16}),
    Reset = send(Grant, {write, 4, 0, <<"reset\n">>}),
    ?assertEqual({error, eio}, reply_within(Held, 1000)),
    ?assertEqual({error, eio}, reply_within(Read, 1000)),
    Fresh = driver_started(),
    ?assertEqual({ok, 6, 0}, reply_within(Reset, 1000)),
    ?assertNot(is_process_alive(Driver)),
    After = send(Grant, {write, 3, 0, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Fresh, 1000),
    Fresh ! {written, Ref},
    ?assertEqual({ok, 3, 0}, reply_within(After, 1000)),
    stop(Line).

%% A reset goes ahead of the writes before it: with one write held by the driver and
%% another waiting behind it, the reset still begins, both writes answer eio, and the
%% fresh driver is handed neither.
a_reset_goes_ahead_of_waiting_writes_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    {ok, _} = call(Grant, {walk, 1, 6, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 6, ?O_WRONLY}),
    Held = send(Grant, {write, 3, 0, <<"stuck">>}),
    {_, <<"stuck">>} = output(Driver, 1000),
    Behind = send(Grant, {write, 6, 0, <<"next">>}),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    ?assertEqual({error, eio}, reply_within(Held, 1000)),
    ?assertEqual({error, eio}, reply_within(Behind, 1000)),
    Fresh = driver_started(),
    ?assertEqual({ok, 5, 0}, reply_within(Reset, 1000)),
    ?assertEqual(none, output(Fresh, 100)),
    stop(Line).

%% Bytes the old driver delivered before a reset are not read after it.
a_reset_drops_what_the_old_driver_read_test() ->
    #{grant := Grant, line := Keeper, driver := Driver} = Line = line(),
    ok = input(Driver, <<"old">>),
    _ = sys:get_state(Keeper),
    ?assertEqual({ok, 5, 0}, call(Grant, {write, 4, 0, <<"reset">>})),
    Fresh = driver_started(),
    Fresh ! {input, <<"new">>},
    ?assertEqual({ok, <<"new">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% ctl takes reset alone; anything else is einval, and ctl does not open for reading.
ctl_takes_reset_alone_test() ->
    #{grant := Grant} = Line = line(),
    ?assertEqual({error, einval}, call(Grant, {write, 4, 0, <<"off">>})),
    ?assertEqual({error, einval}, call(Grant, {write, 4, 0, <<"reset\n\n">>})),
    {ok, _} = call(Grant, {walk, 1, 6, [<<"ctl">>]}),
    ?assertEqual({error, eacces}, call(Grant, {lopen, 6, ?O_RDONLY})),
    stop(Line).

%% Input past line_rx_max breaks the line: what was buffered is dropped and reads
%% answer eio until a reset, after which the new driver's bytes are read.
a_broken_line_answers_reads_eio_until_a_reset_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    ok = input(Driver, <<"kept">>),
    ok = input(Driver, binary:copy(<<0>>, ?ERX_LINE_RX_MAX)),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({ok, 5, 0}, call(Grant, {write, 4, 0, <<"reset">>})),
    Fresh = driver_started(),
    Fresh ! {input, <<"new">>},
    ?assertEqual({ok, <<"new">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% parse/1 makes no atom and takes exactly reset, with at most one newline.
parse_test() ->
    ?assertEqual({ok, reset}, erx_line_fs:parse(<<"reset">>)),
    ?assertEqual({ok, reset}, erx_line_fs:parse(<<"reset\n">>)),
    ?assertEqual({error, einval}, erx_line_fs:parse(<<>>)),
    ?assertEqual({error, einval}, erx_line_fs:parse(<<"Reset">>)),
    ?assertEqual({error, einval}, erx_line_fs:parse(binary:copy(<<"reset">>, 4))).

%% The keeper and the tree's grants (docs/design-bluetooth.md, "The shared line 153") ---

%% The tree's grants, the process the line is linked to besides its driver.
grants(#{line := Line, driver := Driver}) ->
    {links, Links} = process_info(Line, links),
    [Grants] = Links -- [Driver],
    Grants.

%% The line starts its tree's grants, and a grant of them reads and writes data through
%% the line.
the_line_starts_its_trees_grants_test() ->
    #{driver := Driver} = Fixture = line(),
    {ok, Grant} = erx_fs_grants:own(grants(Fixture)),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_LINE_TREE_BYTES, 0}),
    {ok, _} = call(Grant, {walk, 1, 2, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDWR}),
    Write = send(Grant, {write, 2, 0, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Driver, 1000),
    Driver ! {written, Ref},
    ?assertMatch({ok, 3, _}, reply_within(Write, 1000)),
    Read = send(Grant, {read, 2, 0, 16}),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, reply_within(Read, 1000)),
    stop(Fixture).

%% The keeper's end ends its grants, and a read it held answers eio; the grants' end
%% ends the keeper, so its group restarts both together.
the_keeper_and_its_grants_end_together_test() ->
    #{line := Line, grant := Grant} = First = line(),
    Grants = grants(First),
    Watch = monitor(process, Grants),
    Held = send(Grant, {read, 2, 0, 16}),
    exit(Line, kill),
    ?assertEqual({error, eio}, reply_within(Held, 1000)),
    receive {'DOWN', Watch, process, Grants, _} -> ok after 1000 -> erlang:error(grants_kept) end,
    exit(Grant, kill),
    #{line := Again} = Second = line(),
    Keeper = monitor(process, Again),
    exit(grants(Second), kill),
    receive {'DOWN', Keeper, process, Again, {grants_ended, killed}} -> ok after 1000 -> erlang:error(keeper_kept) end,
    exit(maps:get(grant, Second), kill).
