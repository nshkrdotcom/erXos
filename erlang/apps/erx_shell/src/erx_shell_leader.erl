%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_leader).
-moduledoc """
A job's leader: the group leader of every process a job starts, which ends
them all when the process that started the leader ends, so no process a job
started outlives the shell or the exec it ran under. It stands in for the
runtime's job tag (docs/design-shell.md, "Jobs and their tags"; TODO.md, "a
job's processes are found by group leader"). The command shell starts one per job (erx_shell), and `rc -c` on
a tty one for its whole command (erx_shell_script:command/2).

A process joins the job by having the leader as its group leader, which
everything it spawns inherits, so membership needs no list: the processes a
leader leads are found by asking each process for its group leader.

The leader passes each io request on to the terminal's group, which answers
the requester itself, and drops any other message. It ends every process it
leads, and then itself, when its starter ends, for any reason; release/2
ends the job's processes at once (`kill`), or lets the leader end on its own
once it leads none (`keep`), as the processes a UNIX job leaves stay in its
process group.
""".

-export([start/1, spawn_member/3, release/2, end_all/1, led_by/1]).

%% How often a released leader looks for the processes its job left running.
-define(LEFTOVER_LOOK_MS, 1000).

-doc """
Starts a leader for a job of the calling process whose io goes to Group, the
terminal's group. The leader ends what it leads once the caller ends.
""".
-spec start(pid()) -> pid().
start(Group) ->
    Starter = self(),
    spawn(fun() -> forward(Group, monitor(process, Starter), infinity) end).

forward(Group, StarterRef, Look) ->
    receive
        {io_request, _From, _ReplyAs, _Request} = Request ->
            Group ! Request,
            forward(Group, StarterRef, Look);
        {'DOWN', StarterRef, process, _, _} ->
            end_all(self());
        {?MODULE, released} ->
            forward(Group, StarterRef, ?LEFTOVER_LOOK_MS);
        _Other ->
            forward(Group, StarterRef, Look)
    after Look ->
        case led_by(self()) of
            [] -> ok;
            _Left -> forward(Group, StarterRef, Look)
        end
    end.

-doc """
Spawns Body as a process of Leader's job, with a monitor and the spawn
Options: it is given Leader as its group leader before it runs, so
everything it starts is led by Leader too, and it waits for Go, which the
caller calls once it has recorded the process. The caller is not linked to
it: a caller killed between the spawn and the group leader's change leaves
it waiting, unled (TODO.md, "a job's processes are found by group leader").
""".
-spec spawn_member(pid(), fun(() -> term()), [term()]) -> {pid(), reference(), fun(() -> ok)}.
spawn_member(Leader, Body, Options) ->
    Go = make_ref(),
    {Pid, Ref} = spawn_opt(fun() -> receive Go -> Body() end end, [monitor | Options]),
    true = group_leader(Leader, Pid),
    {Pid, Ref, fun() -> Pid ! Go, ok end}.

-doc """
The job's first process has ended. After a crash, the heap limit or an
interrupt (`kill`) every process Leader leads is killed, and then the leader;
after a normal end (`keep`) the processes still running stay with the
leader, unlisted, and end with its starter at the latest.
""".
-spec release(kill | keep, pid()) -> ok.
release(kill, Leader) ->
    ok = end_all(Leader),
    exit(Leader, kill),
    ok;
release(keep, Leader) ->
    Leader ! {?MODULE, released},
    ok.

-doc """
Kills every process Leader leads. Each pass looks at every process. exit/2
is a signal, and the next pass's process_info/2 is a signal from the same
sender to the same process, which arrives after it, so a process a pass
killed is not found again; one started meanwhile is found by the next pass.
The passes end when one finds none, as application_master's kill_all_procs
does.
""".
-spec end_all(pid()) -> ok.
end_all(Leader) ->
    case led_by(Leader) of
        [] ->
            ok;
        Led ->
            lists:foreach(fun(Pid) -> exit(Pid, kill) end, Led),
            end_all(Leader)
    end.

-doc """
The processes Leader leads. The leader is excluded only for clarity: its own
group leader is its starter's.
""".
-spec led_by(pid()) -> [pid()].
led_by(Leader) ->
    [Pid || Pid <- processes(), Pid =/= Leader,
            process_info(Pid, group_leader) =:= {group_leader, Leader}].
