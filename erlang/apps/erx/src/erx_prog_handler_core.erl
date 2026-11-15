%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_core).
-moduledoc """
The decisions of a program's handler (docs/design-programs.md, "The
handler"): one pure state machine, step/2, from an event to the next
state and the actions erx_prog_handler performs, in order.

A handler lives through three phases:

* **reserving**, steps 5 and 6 of "Starting a program": the program's
  holder entry, then each descriptor the starter named, one at a time in
  the order given (a pipe end as an `inherit` with the starter as the
  end's holder, a window's buffer as an allocation and a lease the
  handler holds), then the start itself. Any refusal undoes everything
  reserved, without knowing how far the start went: every hand-off is
  dropped and the lease given back, both of which do nothing to what the
  start took (docs/design-pipes.md, "Hand-offs", Giving back), and the
  holder entry is let go, so the pipe server reads the program's gone.
* **running**: the handler alone sends to the program. Reports from the
  pipe server, and those that arrived while the program was being built,
  queue in arrival order behind the startup message; the head of the
  queue is sent, or for a hand-off installed first and then sent with the
  values the install gave. A send the driver answers `busy` stays at the
  head, owed, until the program frees room, so nothing newer passes it.
  The program's notices go to the pipe server as events naming the
  program. Its requests are answered on their own reply slots, each
  reply queued like a report, so it reaches the program after every
  frame queued before it (Requests, below).
* **ended**: the program's exit status reached the handler, which tells
  the starter and exits, or its port closed with none, and the handler
  exits without a report.

A stop, asked by the starter or forced by its exit, stops the program's
anchor with `ERX_EXIT_SIGNAL + SIGKILL`, a stop by its session, and the
handler then waits for the exit status like any other end. So a session
process's programs never outlive it, as a program's children never
outlive their parent (docs/design-programs.md, "A program's end").

Every frame from the program passes the program protocol's grammar
(erx_prog_grammar:check_from_program/1) before anything reads it. The
driver delivers only records that decode, within the program's credit,
so at most one request is outstanding on each slot, but it does not judge
their form: a frame the grammar refuses stops the program with
`ERX_EXIT_SIGNAL + SIGSYS`, as the driver stops one for a malformed
record, and the handler carries on until the program's end.

**Requests** (docs/design-programs.md, "The program protocol"). A
`{kill, Target, Signal}` and a `{probe, Target}` reach the processes the
handler's policy lets the program reach: its own children, itself, and
the processes its `signal` right names. This handler keeps no child
record and its program holds no `signal` right, so a program reaches
itself alone, and every other target is `esrch`, whether or not it
exists, so a kill or a probe tells the program nothing of processes
beyond its reach. A probe of itself is `ok`. A kill of itself with
`sigkill` stops the program as a stop does and answers `ok`; with a stop
or continue signal, which belong to the session's job control, it is
`eperm`; with any other signal it is `enosys`, since the protocol has no
report that carries a signal to a program (TODO.md), and a kill answered
`ok` must have signaled.

**Files** (docs/design-programs.md, "Descriptors and files"). The core
holds the program's namespace, narrowed from its starter's
(docs/design-files.md, "Narrowing for a program"), its working directory,
its open table, from each open to the open-file description that serves
it, and its pending file requests by reply slot. A request is relayed as
an action and its answer comes back as an event, so the handler goes on
taking the program's other frames, a kill included, while a file request
waits. An `lopen` or `lcreate` with a flag bit outside 9P2000.L's open
flags, or the access mode 3, is `einval`; one past `ERX_PROG_FDS_MAX`
opens, those pending included, is `emfile`; otherwise it is resolved and
opened over the narrowed namespace alone, and its answer is a new open.
A `read`, `write` or `clunk` of an open not in the table is `ebadf`, and a
data slot past the program's slots is `einval`. A read's answer longer
than the request's count is `eio` and is never copied; otherwise its
bytes are copied into the slot, and the copy's answer is the reply's. A `clunk` takes the open
out of the table at once, and its description closes after the requests
it holds. An error the protocol has no name for is `eio`.

Every other event the core does not expect in its phase leaves the state
as it was and does nothing: the handler's mailbox is reached only by
session code and the program's own driver.
""".

-include("generated/erx_abi.hrl").

-export([new/3, step/2, phase/1]).
-export_type([core/0, event/0, action/0, starter_fd/0, files/0]).

%% A descriptor as the starter names it: a pipe end the starter holds, or a
%% window's buffer of Bytes in the area of the display domain Peer, which
%% the handler allocates and lends to the program (docs/design-display.md,
%% "The pixel area": a buffer mapped into a program belongs to its handler).
-type starter_fd() :: {0..1023, {pipe, term()} | {buffer, pos_integer(), pos_integer()}}.
%% A descriptor as erx_program:start/1 takes it.
-type program_fd() :: {0..1023, {pipe_hand, pos_integer(), term()} | {mem, pos_integer(), pos_integer()}}.

-type event() :: {holder, ok | {error, atom()}}
               | {reserved, {pipe_hand, pos_integer(), term()}}
               | {reserved, {mem, Lease :: pos_integer(), Pages :: pos_integer(), Offset :: non_neg_integer()}}
               | {refused, atom()}
               | started
               | {report, term()}
               | {frame, term()}
               | {sent, ok | busy | {error, atom()}}
               | {installed, term()}
               | {install_refused, atom()}
               | room
               | pipes_lost
               | stop
               | {exit_status, integer()}
               | port_closed
               | {file_opened, slot(), {ok, description()} | {error, atom()}}
               | {file_done, slot(), {ok, binary()} | eof | ok | {error, atom()}}
               | {file_copied, slot(), ok | {error, atom()}}
               | ignored.

%% What the starter hands for the program's files: its namespace table
%% (prim_file:erx_mounts/0), the narrowing, `all` for the whole table or each
%% absolute path the program reaches with its rights there, the program's
%% working directory, and its data area's slots.
-type files() :: #{table := erx_path:table(), within := all | [{binary(), ro | rw | rx}],
                   cwd := binary(), slots := 1..?ERX_PROG_DATA_SLOTS_MAX}.
-type slot() :: non_neg_integer().
%% An open-file description, a session process the effect side made.
-type description() :: pid().
%% A pending file request: the reply case it answers, and for a read or a
%% write its count, and for a read the data slot its bytes go to.
-type pending() :: file_lopen | file_lcreate | file_clunk
                 | {file_read, pos_integer(), slot()} | {file_copied, non_neg_integer()}
                 | {file_write, pos_integer()}.

-type action() :: holder
                | {inherit, term()}
                | {lend, pos_integer(), pos_integer()}
                | {start, [program_fd()]}
                | {answer, {ok, [{0..1023, non_neg_integer()}]} | {error, atom()}}
                | {hand_drop, pos_integer()}
                | {unlend, pos_integer()}
                | holder_drop
                | {send, term()}
                | {install, {pipe_hand, pos_integer(), term()}}
                | {forward, tuple()}
                | {stop, non_neg_integer()}
                | {tell_starter, integer()}
                | {open, slot(), binary(), non_neg_integer(), none | non_neg_integer(),
                   erx_path:table(), erx_path:place()}
                | {read, description(), slot(), pos_integer()}
                | {write, description(), slot(), slot(), pos_integer()}
                | {copy_in, slot(), slot(), binary()}
                | {clunk, description(), slot()}
                | exit.

%% What waits to reach the program, oldest first: a frame to send, or a
%% hand-off to install, whose filled report is then sent.
-type outgoing() :: {frame, term()} | {hand, {pipe_hand, pos_integer(), term()}}.

-record(core, {pid :: pos_integer(),
               phase = reserving :: reserving | running | ended,
               %% reserving: the starter's descriptors not yet reserved, in order.
               todo = [] :: [starter_fd()],
               %% reserving: the reserved descriptors, newest first, for the start
               %% and for the undo of a refusal.
               made = [] :: [program_fd()],
               %% reserving: each buffer's offset in its area, for the starter.
               offsets = [] :: [{0..1023, non_neg_integer()}],
               queue = queue:new() :: queue:queue(outgoing()),
               %% The head of the queue is out: sent and not yet answered, or
               %% answered busy and owed until the program frees room; or a
               %% frame was lost, and nothing more is sent to the program.
               out = false :: false | sending | owed | lost,
               %% A stop was asked once; a second asks nothing more.
               stopping = false :: boolean(),
               %% The program's narrowed namespace and working directory.
               table = [] :: erx_path:table(),
               cwd = [] :: erx_path:place(),
               slots = 1 :: 1..?ERX_PROG_DATA_SLOTS_MAX,
               opens = #{} :: #{0..65535 => description()},
               pending = #{} :: #{slot() => pending()}}).
-opaque core() :: #core{}.

-define(IS_FD(N), (is_integer(N) andalso N >= 0 andalso N < ?ERX_PROG_FDS_MAX)).
-define(IS_POS(N), (is_integer(N) andalso N > 0)).
-define(IS_PID(P), (is_integer(P) andalso P >= 2 andalso P =< 16#7fffffff)).
%% A stop by the session reads as signaled SIGKILL (docs/design-programs.md,
%% "A program's end").
-define(STOP_STATUS, (?ERX_EXIT_SIGNAL + ?ERX_SIGKILL)).
%% A program whose frame the grammar refuses ends signaled SIGSYS
%% (docs/design-programs.md, "Credit").
-define(REFUSED_STATUS, (?ERX_EXIT_SIGNAL + ?ERX_SIGSYS)).
%% 9P2000.L's open flags a program may send (abi/protocols/9p.txt).
-define(OPEN_FLAGS, (?ERX_P9_O_ACCMODE bor ?ERX_P9_O_TRUNC bor ?ERX_P9_O_EXCL bor ?ERX_P9_O_APPEND
                     bor ?ERX_P9_O_SYNC)).

-doc """
A handler for program `Pid` that starts it with the starter's
descriptors `Fds` and serves its files as `Files` says, and its first
action; or `{error, einval}` for a `Pid` outside 2..2^31-1, a descriptor
of another form, a number named twice, more than one buffer, which the
program may have only one of, a working directory that is not an
absolute path of plain names, slots outside 1..`ERX_PROG_DATA_SLOTS_MAX`,
or a narrowing path named twice or not absolute; `{error, enoent}` for a
narrowing path that no entry of the table holds; or `{error, eacces}` for
rights the starter does not hold there.
""".
-spec new(term(), term(), files()) -> {ok, core(), [action()]} | {error, einval | enoent | eacces}.
new(Pid, Fds, #{table := Table, within := Within, cwd := Cwd, slots := Slots})
  when ?IS_PID(Pid), is_list(Fds), is_integer(Slots), Slots >= 1, Slots =< ?ERX_PROG_DATA_SLOTS_MAX ->
    case {valid_fds(Fds), erx_path:cwd(Cwd), narrowed(Table, Within)} of
        {false, _, _} -> {error, einval};
        {_, error, _} -> {error, einval};
        {_, _, {error, _} = Refused} -> Refused;
        {true, {ok, Place}, {ok, Narrowed}} ->
            {ok, #core{pid = Pid, todo = Fds, table = Narrowed, cwd = Place, slots = Slots}, [holder]}
    end;
new(_Pid, _Fds, _Files) ->
    {error, einval}.

%% The program's namespace (docs/design-files.md, "Narrowing for a
%% program"): the starter's whole table, or for each path the starter names
%% an entry at that path, on the provider of the starter's entry that holds
%% it, rooted where the path lies there, with the rights asked, the
%% starter's own there or read-only; and each of the starter's entries
%% below the path, read-only when read-only was asked, so the program sees
%% at every path below it what the starter sees. Nothing above a narrowed
%% path stays, so the paths above it read as the empty root.
narrowed(Table, all) ->
    {ok, Table};
narrowed(Table, Within) when is_list(Within) ->
    Groups = [narrowed_entries(Table, Path) || Path <- Within],
    Entries = lists:append([Group || Group <- Groups, is_list(Group)]),
    Points = [Point || #{point := Point} <- Entries],
    case {[Refused || {error, Refused} <- Groups], length(lists:usort(Points)) =:= length(Points)} of
        {[Refused | _], _} -> {error, Refused};
        {[], false} -> {error, einval};
        {[], true} -> {ok, Entries}
    end;
narrowed(_Table, _Within) ->
    {error, einval}.

narrowed_entries(Table, {Path, Rights}) when Rights =:= ro; Rights =:= rw; Rights =:= rx ->
    case erx_path:cwd(Path) of
        {ok, Place} -> narrowed_at(deepest_entry(Table, Place), Place, Rights, Table);
        error -> {error, einval}
    end;
narrowed_entries(_Table, _Path) ->
    {error, einval}.

%% The deepest entry whose point Place lies at or under, as a resolution
%% picks it, or none.
deepest_entry(Table, Place) ->
    case [Entry || #{point := Point} = Entry <- Table, lists:prefix(Point, Place)] of
        [] -> none;
        Holding -> lists:last(lists:sort(fun shallower/2, Holding))
    end.

shallower(#{point := A}, #{point := B}) -> length(A) =< length(B).

narrowed_at(none, _Place, _Rights, _Table) ->
    {error, enoent};
narrowed_at(#{point := Point, root := Root, rights := Own} = Entry, Place, Rights, Table)
  when Rights =:= Own; Rights =:= ro ->
    Below = [Mount#{rights := below_rights(Rights, Mount)}
             || #{point := Under} = Mount <- Table, Under =/= Place, lists:prefix(Place, Under)],
    [Entry#{point := Place, root := Root ++ lists:nthtail(length(Point), Place), rights := Rights}
     | Below];
narrowed_at(_Entry, _Place, _Rights, _Table) ->
    {error, eacces}.

below_rights(ro, _Mount) -> ro;
below_rights(_Own, #{rights := Rights}) -> Rights.

-doc "The handler's phase: `reserving`, `running` or `ended`.".
-spec phase(core()) -> reserving | running | ended.
phase(#core{phase = Phase}) -> Phase.

-doc "The next state and the actions that carry out one event.".
-spec step(core(), event()) -> {core(), [action()]}.
%% Reserving: one descriptor at a time, then the start.
step(#core{phase = reserving} = C, {holder, ok}) ->
    reserve_next(C);
step(#core{phase = reserving} = C, {holder, {error, Errno}}) when is_atom(Errno) ->
    %% No entry was made for this handler, so it has nothing to let go.
    %% eexist: the pid has an entry, another handler speaks for it, and
    %% the starter named a pid that is not its program's.
    {C#core{phase = ended}, [{answer, {error, holder_errno(Errno)}}, exit]};
step(#core{phase = reserving, todo = [{N, {pipe, _}} | Todo], made = Made} = C,
     {reserved, {pipe_hand, Number, _Term} = Hand}) when ?IS_POS(Number) ->
    reserve_next(C#core{todo = Todo, made = [{N, Hand} | Made]});
step(#core{phase = reserving, todo = [{N, {buffer, _, _}} | Todo], made = Made, offsets = Offsets} = C,
     {reserved, {mem, Lease, Pages, Offset}}) when ?IS_POS(Lease), ?IS_POS(Pages) ->
    reserve_next(C#core{todo = Todo, made = [{N, {mem, Lease, Pages}} | Made],
                        offsets = [{N, Offset} | Offsets]});
step(#core{phase = reserving} = C, {refused, Errno}) when is_atom(Errno) ->
    {C#core{phase = ended}, undo(C) ++ [{answer, {error, Errno}}, exit]};
step(#core{phase = reserving, todo = []} = C, started) ->
    {C1, Actions} = pump(C#core{phase = running}),
    {C1, [{answer, {ok, lists:reverse(C#core.offsets)}} | Actions]};
%% Reports queue from the first: those that arrive while the program is
%% built wait behind its startup message, which the start wrote.
step(#core{phase = Phase} = C, {report, Report}) when Phase =/= ended ->
    pump(enqueue(C, outgoing(Report)));
step(#core{phase = Phase} = C, pipes_lost) when Phase =/= ended ->
    pump(enqueue(C, {frame, {erx_prog, 1, pipe_server_lost}}));
%% Running: the queue's head, and the program's notices.
step(#core{phase = running, out = sending} = C, {sent, ok}) ->
    pump(drop_head(C));
step(#core{phase = running, out = sending} = C, {sent, busy}) ->
    {C#core{out = owed}, []};
step(#core{phase = running, out = sending} = C, {sent, {error, _}}) ->
    %% A frame the driver refused is lost, and a running program must never
    %% miss a report and read the later ones, so nothing more is sent and the
    %% program is stopped, as a refused install's pass stops it; one already
    %% ending refuses the stop.
    stop(C#core{out = lost, queue = queue:new()}, ?STOP_STATUS);
step(#core{phase = running, out = owed} = C, room) ->
    pump(C#core{out = false});
step(#core{phase = running, out = sending, queue = Q} = C, {installed, Filled}) ->
    %% The values the install gave stand where the hand-off named copies.
    pump(C#core{out = false, queue = queue:in_r({frame, {erx_prog, 1, Filled}}, queue:drop(Q))});
step(#core{phase = running, out = sending, queue = Q} = C, {install_refused, _}) ->
    %% The end the report concerns stays the program's and is lost
    %% (docs/design-pipes.md, "Hand-offs").
    {hand, {pipe_hand, _, Report}} = queue:head(Q),
    {C1, Actions} = pump(drop_head(C)),
    {C1, [{forward, {install_failed, holder(C), element(2, Report), element(3, Report)}} | Actions]};
step(#core{phase = running} = C, {frame, Frame}) ->
    case erx_prog_grammar:check_from_program(Frame) of
        ok -> from_program(C, Frame);
        {error, _} -> stop(C, ?REFUSED_STATUS)
    end;
step(#core{phase = running} = C, stop) ->
    stop(C, ?STOP_STATUS);
step(#core{phase = running} = C, {exit_status, Status}) when is_integer(Status) ->
    {C#core{phase = ended, queue = queue:new()}, [{tell_starter, Status}, exit]};
step(#core{phase = running} = C, port_closed) ->
    %% The port closed with no status: a record of the end may be lost, and
    %% the starter is told nothing the handler did not read.
    {C#core{phase = ended, queue = queue:new()}, [exit]};
step(#core{phase = running, pending = Pending} = C, {file_opened, Slot, Result}) ->
    case maps:take(Slot, Pending) of
        {Case, Rest} when Case =:= file_lopen; Case =:= file_lcreate ->
            opened(C#core{pending = Rest}, Slot, Case, Result);
        _ ->
            {C, []}
    end;
step(#core{phase = running, pending = Pending} = C, {file_done, Slot, Result}) ->
    case maps:take(Slot, Pending) of
        {{file_read, _, _} = Waiting, Rest} -> done(C#core{pending = Rest}, Slot, Waiting, Result);
        {{file_write, _} = Waiting, Rest} -> done(C#core{pending = Rest}, Slot, Waiting, Result);
        {file_clunk, Rest} -> done(C#core{pending = Rest}, Slot, file_clunk, Result);
        _ -> {C, []}
    end;
step(#core{phase = running, pending = Pending} = C, {file_copied, Slot, Result}) ->
    case {maps:take(Slot, Pending), Result} of
        {{{file_copied, Done}, Rest}, ok} -> file_reply(C#core{pending = Rest}, file_read, Slot, {ok, Done});
        {{{file_copied, _}, Rest}, {error, Errno}} -> file_reply(C#core{pending = Rest}, file_read, Slot, {error, Errno});
        _ -> {C, []}
    end;
step(C, _Event) ->
    {C, []}.

%% A stop of the program with Status, asked once.
stop(#core{stopping = false} = C, Status) -> {C#core{stopping = true}, [{stop, Status}]};
stop(C, _Status) -> {C, []}.

%% A frame from the program, which the grammar accepted.
from_program(C, {erx_prog, _, {closed, Pipe, End}}) ->
    {C, [{forward, {closed, holder(C), Pipe, End}}]};
from_program(C, {erx_prog, _, {drained, Pipe, End, Writer}}) ->
    {C, [{forward, {drained, holder(C), Pipe, End, Writer}}]};
from_program(C, {erx_prog, _, Slot, {kill, Target, Signal}}) ->
    case reach(C, Target) of
        none -> reply(C, kill, Slot, {error, esrch});
        self -> kill_self(C, Slot, Signal)
    end;
from_program(C, {erx_prog, _, Slot, {probe, Target}}) ->
    case reach(C, Target) of
        none -> reply(C, probe, Slot, {error, esrch});
        self -> reply(C, probe, Slot, ok)
    end;
from_program(C, {erx_prog, _, Slot, {file, lopen, Path, Flags}}) ->
    open(C, Slot, file_lopen, Path, Flags, none);
from_program(C, {erx_prog, _, Slot, {file, lcreate, Path, Flags, Mode}}) ->
    open(C, Slot, file_lcreate, Path, Flags, Mode);
from_program(C, {erx_prog, _, Slot, {file, read, Open, Count, Data}}) ->
    on_open(C, Slot, file_read, Open, Data,
            fun(Desc) -> {{file_read, Count, Data}, {read, Desc, Slot, Count}} end);
from_program(C, {erx_prog, _, Slot, {file, write, Open, Count, Data}}) ->
    on_open(C, Slot, file_write, Open, Data,
            fun(Desc) -> {{file_write, Count}, {write, Desc, Slot, Data, Count}} end);
from_program(#core{opens = Opens} = C, {erx_prog, _, Slot, {file, clunk, Open}}) ->
    case maps:take(Open, Opens) of
        {Desc, Rest} -> relay(C#core{opens = Rest}, Slot, file_clunk, {clunk, Desc, Slot});
        error -> file_reply(C, file_clunk, Slot, {error, ebadf})
    end.

%% An lopen or an lcreate, relayed to be resolved over the program's
%% namespace from its working directory, or refused.
open(#core{opens = Opens, pending = Pending, table = Table, cwd = Cwd} = C, Slot, Case, Path, Flags, Mode) ->
    Opening = length([P || P <- maps:values(Pending), P =:= file_lopen orelse P =:= file_lcreate]),
    if
        Flags band bnot ?OPEN_FLAGS =/= 0; Flags band ?ERX_P9_O_ACCMODE =:= ?ERX_P9_O_ACCMODE ->
            file_reply(C, Case, Slot, {error, einval});
        map_size(Opens) + Opening >= ?ERX_PROG_FDS_MAX ->
            file_reply(C, Case, Slot, {error, emfile});
        true ->
            relay(C, Slot, Case, {open, Slot, Path, Flags, Mode, Table, Cwd})
    end.

%% A read or a write of Open through data slot Data, relayed to the open's
%% description as Relay says, or refused.
on_open(#core{opens = Opens, slots = Slots} = C, Slot, Case, Open, Data, Relay) ->
    case maps:find(Open, Opens) of
        error ->
            file_reply(C, Case, Slot, {error, ebadf});
        {ok, _} when Data >= Slots ->
            file_reply(C, Case, Slot, {error, einval});
        {ok, Desc} ->
            {Waiting, Action} = Relay(Desc),
            relay(C, Slot, Waiting, Action)
    end.

%% A request handed on, its slot waiting for the answer.
relay(#core{pending = Pending} = C, Slot, Waiting, Action) ->
    {C#core{pending = Pending#{Slot => Waiting}}, [Action]}.

%% An open's answer: the lowest open number free names the description.
opened(#core{opens = Opens} = C, Slot, Case, {ok, Desc}) ->
    Open = hd([N || N <- lists:seq(0, ?ERX_PROG_FDS_MAX - 1), not is_map_key(N, Opens)]),
    file_reply(C#core{opens = Opens#{Open => Desc}}, Case, Slot, {ok, Open});
opened(C, Slot, Case, {error, Errno}) ->
    file_reply(C, Case, Slot, {error, Errno}).

%% A read's, a write's or a clunk's answer. A read's bytes are copied into
%% the data slot, and the copy's answer, file_copied, gives the reply that
%% names their count; never more bytes than the request asked for are
%% copied, which no grammar can hold a reply to.
done(C, Slot, {file_read, Count, Data}, {ok, Bytes}) when byte_size(Bytes) =< Count ->
    relay(C, Slot, {file_copied, byte_size(Bytes)}, {copy_in, Slot, Data, Bytes});
done(C, Slot, {file_read, _, _}, {ok, _TooMany}) ->
    file_reply(C, file_read, Slot, {error, eio});
done(C, Slot, {file_read, _, _}, eof) ->
    file_reply(C, file_read, Slot, {ok, 0});
done(C, Slot, {file_write, Count}, ok) ->
    file_reply(C, file_write, Slot, {ok, Count});
done(C, Slot, file_clunk, ok) ->
    file_reply(C, file_clunk, Slot, ok);
done(C, Slot, Waiting, {error, Errno}) ->
    file_reply(C, case_of(Waiting), Slot, {error, Errno}).

case_of({Case, _, _}) -> Case;
case_of({Case, _}) -> Case;
case_of(Case) -> Case.

%% A file request's reply. Its error comes from a file server or the
%% release, whose names the protocol may lack; one it lacks is eio.
file_reply(C, Case, Slot, {error, Errno}) ->
    case erx_prog_grammar:build_reply(Case, Slot, {error, Errno}) of
        {ok, _} -> reply(C, Case, Slot, {error, Errno});
        {error, _} -> reply(C, Case, Slot, {error, eio})
    end;
file_reply(C, Case, Slot, Value) ->
    reply(C, Case, Slot, Value).

%% A kill of the program itself. A signal whose default action in the
%% signal table is stop or continue belongs to the session's job control.
kill_self(C, Slot, Signal) ->
    case {Signal, erx_abi_signals:default_action(Signal)} of
        {_, Action} when Action =:= stop; Action =:= continue ->
            reply(C, kill, Slot, {error, eperm});
        {sigkill, _} ->
            {C1, Stop} = stop(C, ?STOP_STATUS),
            {C2, Sent} = reply(C1, kill, Slot, ok),
            {C2, Stop ++ Sent};
        _ ->
            reply(C, kill, Slot, {error, enosys})
    end.

%% Whom a kill or a probe of Target reaches: the program itself, or no one,
%% as the handler keeps no child record and the program holds no signal right.
reach(#core{pid = Pid}, Pid) -> self;
reach(_C, _Target) -> none.

%% The reply Value to the request of case Request on Slot, queued behind the
%% frames already waiting. The handler builds every reply it sends, so one
%% the grammar refuses is the handler's bug, and crashes it.
reply(C, Request, Slot, Value) ->
    {ok, Frame} = erx_prog_grammar:build_reply(Request, Slot, Value),
    pump(enqueue(C, {frame, Frame})).

%% The next descriptor's reservation, or the start once none is left.
reserve_next(#core{todo = [{_N, {pipe, End}} | _]} = C) ->
    {C, [{inherit, End}]};
reserve_next(#core{todo = [{_N, {buffer, Peer, Bytes}} | _]} = C) ->
    {C, [{lend, Peer, Bytes}]};
reserve_next(#core{todo = [], made = Made} = C) ->
    {C, [{start, lists:reverse(Made)}]}.

%% Everything a refused start reserved, given back whatever the start took.
undo(#core{made = Newest}) ->
    Made = lists:reverse(Newest),
    [{hand_drop, Number} || {_, {pipe_hand, Number, _}} <- Made] ++
        [{unlend, Lease} || {_, {mem, Lease, _}} <- Made] ++
        [holder_drop].

%% Sends the queue's head when nothing is out.
pump(#core{phase = running, out = false, queue = Q} = C) ->
    case queue:peek(Q) of
        {value, {frame, Frame}} -> {C#core{out = sending}, [{send, Frame}]};
        {value, {hand, Hand}} -> {C#core{out = sending}, [{install, Hand}]};
        empty -> {C, []}
    end;
pump(C) ->
    {C, []}.

enqueue(#core{queue = Q} = C, Out) ->
    C#core{queue = queue:in(Out, Q)}.

drop_head(#core{queue = Q} = C) ->
    C#core{out = false, queue = queue:drop(Q)}.

%% A report that lists copies arrives as the pipe server's hand-off.
outgoing({pipe_hand, Number, _Term} = Hand) when ?IS_POS(Number) -> {hand, Hand};
outgoing(Report) -> {frame, {erx_prog, 1, Report}}.

holder(#core{pid = Pid}) -> {program, Pid}.

holder_errno(eexist) -> einval;
holder_errno(Errno) -> Errno.

%% Each number once, each descriptor of a starter's form, at most one buffer.
valid_fds(Fds) ->
    Numbers = [N || {N, _} <- Fds],
    lists:all(fun valid_fd/1, Fds)
        andalso length(lists:usort(Numbers)) =:= length(Fds)
        andalso length([B || {_, {buffer, _, _}} = B <- Fds]) =< 1.

valid_fd({N, {pipe, _End}}) when ?IS_FD(N) -> true;
valid_fd({N, {buffer, Peer, Bytes}}) when ?IS_FD(N), ?IS_POS(Peer), ?IS_POS(Bytes) -> true;
valid_fd(_) -> false.
