%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_relay).
-behaviour(gen_server).
-moduledoc """
The terminal relay (docs/design-shell.md, "The terminal relay's protocol"):
the gen_server registered as erx_tty_owner, the effects around the pure
core erx_session_relay_core. Every request goes to request/3 and every
other message to event/2; the relay answers the request first and then
carries out the core's actions in the order the core gives them, so a
caller sees its answer before anything the request set off.

The client functions below make every request, so this is the one module
of the session's code that names erx_tty_owner; the chokepoint rules
`relay-readers` and `relay-name` (tools/lib/erx/chokepoint_rules/relay.rb)
keep it so. open_reader/1 is the one way to an open made for reading.

The core trusts the shape of what it is given, so the relay checks what
arrives before the core sees it, and drops a message it cannot take:

* a group the shell or the console names must be a process of this node,
  since the core monitors every group it meets;
* the name of an open is the relay's own, a reference made per open;
* a writer's bytes must be iodata, and its reply address a pid with a
  reference;
* a monitor's `'DOWN'`, the console's and the master's included, and a
  timer's message, a read's or a resend's, are taken only with the
  reference the relay holds for them, so a message made to look like one
  ends no relay, hangs nothing up, closes no open, ends no wait and starts
  no resend;
* a message from the master arrives as `{erx_origin, D, Msg}` from a master
  in another domain, taken only when D is the master's domain, or plain
  from a master in this domain, whose end hangs the tty up.

The relay is its console's line and ends with it.
""".

-export([start_link/2]).
-export([open_reader/1, open_writer/1, close/1, tty/2, watch/2, read/3, write/2,
         console_group/1, status/1, foreground/2, foreground/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(NAME, erx_tty_owner).
-define(RESEND_MS, 1000).

-type master() :: none
                | {local, pid(), reference()}   % in this domain, monitored
                | {domain, pid(), non_neg_integer()}. % in domain D, enveloped

-record(state, {
    core :: erx_session_relay_core:core(),
    %% The console and the monitor that ends the relay with it.
    console :: {pid(), reference()},
    master :: master(),
    %% The processes the core asked to watch, each monitored once.
    monitored = #{} :: #{pid() => reference()},
    %% The timers running, by the core event each delivers, with the
    %% reference its message carries.
    timers = #{} :: #{erx_session_relay_core:event() => reference()}
}).

%%% Starting

-doc """
Starts the relay registered as erx_tty_owner, linked to the caller, for
Console, the console of the session role, and Master, the tty's master:
a process of this domain, one of another domain, or `undefined` for none.
""".
-spec start_link(pid(), pid() | undefined) -> gen_server:start_ret().
start_link(Console, Master) when is_pid(Console) ->
    gen_server:start_link({local, ?NAME}, ?MODULE, {Console, origin(Master)}, []).

%%% Client functions: every request to the relay

-doc "An open of the terminal made for reading, for Holder: `console` or a job's tag.".
-spec open_reader(term()) -> {ok, reference()} | {error, einval}.
open_reader(Holder) -> call({open, Holder, read}).

-doc "A write-only open of the terminal for Holder: `console` or a job's tag.".
-spec open_writer(term()) -> {ok, reference()} | {error, einval}.
open_writer(Holder) -> call({open, Holder, write}).

-doc "Closes Open; no report for it follows the answer.".
-spec close(reference()) -> ok | {error, ebadf}.
close(Open) -> call({close, Open}).

-doc "`tcgetattr`, `winsize`, `{tcsetattr, T}` or `{tcsetattr, T, sigttou_ignored}` on Open.".
-spec tty(reference(), term()) -> erx_session_relay_core:answer().
tty(Open, Request) -> call({tty, Open, Request}).

-doc """
Watches Open for Kind, `{read, Count}`, `in` or `out`; the report is
`{ready, Open, [Kind], N}`.
""".
-spec watch(reference(), term()) -> ok | {error, einval | ebadf}.
watch(Open, Kind) -> call({watch, Open, [Kind]}).

-doc "Reads at most Max bytes from Open, after the report numbered N.".
-spec read(reference(), 0..4096, integer()) -> erx_session_relay_core:answer().
read(Open, Max, N) -> call({tty_read, Open, Max, N}).

-doc "Writes Bytes, at most 4 KiB, through Open.".
-spec write(reference(), binary()) -> {ok, non_neg_integer()} | eagain | {error, einval | ebadf}.
write(Open, Bytes) -> call({write, Open, Bytes}).

-doc "The console names its current group, which its events carry from now on.".
-spec console_group(pid()) -> ok | {error, einval}.
console_group(Group) -> call({console_group, Group}).

-doc "The shell's `Ctrl-T` status line.".
-spec status(binary()) -> ok | {error, einval}.
status(Line) -> call({status, Line}).

-doc "The shell gives the terminal to the console, Signals being `{Group, Seen}`.".
-spec foreground(console, {pid(), non_neg_integer()}) -> erx_session_relay_core:answer().
foreground(console, Signals) -> call({foreground, console, Signals}).

-doc "The shell gives the terminal to the job Tag with Mode: `cooked`, `current` or a termios.".
-spec foreground(term(), term(), {pid(), non_neg_integer()}) -> erx_session_relay_core:answer().
foreground(Tag, Mode, Signals) -> call({foreground, Tag, Mode, Signals}).

call(Request) -> gen_server:call(?NAME, Request, infinity).

%%% The server

-doc false.
%% Origin is origin/1's, found in start_link's caller; a test of a master in
%% another domain starts the server with it, as stock's emulator cannot name one.
init({Console, Origin}) ->
    Master = watched(Origin),
    announce(Master),
    {ok, #state{core = erx_session_relay_core:new(Console, #{master => presence(Master)}),
                console = {Console, erlang:monitor(process, Console)},
                master = Master}}.

%% The master, if any, and where its messages come from: plain from a master in
%% this domain, which the relay watches, so that its end hangs the tty up;
%% enveloped from one in domain D, which says tty_hangup itself.
origin(undefined) -> none;
origin(Pid) when node(Pid) =:= node() -> {local, Pid};
origin(Pid) when is_pid(Pid) -> {domain, Pid, erx:owner(Pid)}.

watched({local, Pid}) -> {local, Pid, erlang:monitor(process, Pid)};
watched(Origin) -> Origin.

master_pid({local, Pid, _Ref}) -> Pid;
master_pid({domain, Pid, _D}) -> Pid.

presence(none) -> none;
presence(_Master) -> present.

%% The tty names itself to its master (docs/design-live.md, "Between
%% domains"), at the start and again with each resend erx_tty_link asks for.
announce(none) -> ok;
announce(Master) -> master_pid(Master) ! {tty_open, self()}, ok.

-doc false.
handle_call(Request, {Caller, _Tag} = From, #state{core = Core0} = State) ->
    {Answer, Actions, Core} =
        case checked(Request) of
            {ok, Checked} -> erx_session_relay_core:request(Caller, Checked, Core0);
            refused -> {{error, einval}, [], Core0}
        end,
    gen_server:reply(From, Answer),
    {noreply, carry_out(Actions, State#state{core = Core})}.

%% A request as the core takes it, or `refused`: the relay names each open,
%% and every group named must be a process of this node, which the core has
%% the relay monitor.
checked({open, Holder, Mode}) -> {ok, {open, Holder, Mode, make_ref()}};
checked({open, _Holder, _Mode, _Open}) -> refused;
checked({console_group, Group} = Request) -> group_checked(Group, Request);
checked({foreground, console, {Group, _}} = Request) -> group_checked(Group, Request);
checked({foreground, _Tag, _Mode, {Group, _}} = Request) -> group_checked(Group, Request);
checked(Request) -> {ok, Request}.

group_checked(Group, Request) when is_pid(Group), node(Group) =:= node() ->
    {ok, Request};
group_checked(_Group, _Request) ->
    refused.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

%% The console's and the master's 'DOWN' come first; any other is taken only
%% for a monitor the core asked for, with its reference.
-doc false.
handle_info({'DOWN', Ref, process, Pid, _}, #state{console = {Pid, Ref}} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Ref, process, Pid, _}, #state{master = {local, Pid, Ref}} = State) ->
    event({master, tty_hangup}, State);
handle_info({'DOWN', Ref, process, Pid, _}, #state{monitored = Monitored} = State) ->
    case Monitored of
        #{Pid := Ref} ->
            event({down, Pid}, State#state{monitored = maps:remove(Pid, Monitored)});
        #{} ->
            {noreply, State}
    end;
handle_info({timeout, Ref, Event}, #state{timers = Timers} = State) ->
    case Timers of
        #{Event := Ref} -> event(Event, State#state{timers = maps:remove(Event, Timers)});
        #{} -> {noreply, State}
    end;
handle_info({erx_console_output, From, Bytes}, #state{console = {Console, _}} = State) ->
    take_write({Console, {erx_console_written, From}}, Bytes, State);
handle_info({tty_write, From, Ref, Bytes}, State) when is_pid(From), is_reference(Ref) ->
    take_write({From, {Ref, ok}}, Bytes, State);
handle_info({tty_drain, From, Ref}, State) when is_pid(From), is_reference(Ref) ->
    event({drain, {From, {Ref, ok}}}, State);
handle_info({erx_origin, D, Message}, #state{master = {domain, _Pid, D}} = State) ->
    event({master, Message}, State);
handle_info({erx_origin, _D, _Message}, State) ->
    {noreply, State};
%% A plain message comes from this domain by construction; with a master in
%% it, every other plain message is the master's (docs/design-shell.md, "Its
%% parties"), and
%% erx_tty_link drops a shape it does not know.
handle_info(Message, #state{master = {local, _Pid, _Ref}} = State) ->
    event({master, Message}, State);
handle_info(_Message, State) ->
    {noreply, State}.

%% A writer's message joins the output queue as one binary; one whose bytes
%% are not iodata is dropped.
take_write(Done, Bytes, State) ->
    try iolist_to_binary(Bytes) of
        Binary -> event({write, Done, Binary}, State)
    catch
        error:badarg -> {noreply, State}
    end.

event(Event, #state{core = Core0} = State) ->
    {Actions, Core} = erx_session_relay_core:event(Event, Core0),
    {noreply, carry_out(Actions, State#state{core = Core})}.

%%% The core's actions, in the order it gives them

carry_out(Actions, State) ->
    lists:foldl(fun carry_out_one/2, State, Actions).

carry_out_one({send, To, Message}, State) ->
    To ! Message,
    State;
carry_out_one({monitor, Pid}, #state{monitored = Monitored} = State)
  when is_map_key(Pid, Monitored) ->
    State;
carry_out_one({monitor, Pid}, #state{monitored = Monitored} = State) ->
    State#state{monitored = Monitored#{Pid => erlang:monitor(process, Pid)}};
carry_out_one({output, N, Bytes}, #state{master = Master} = State) ->
    master_pid(Master) ! {tty_output, N, Bytes},
    State;
carry_out_one(open, #state{master = Master} = State) ->
    announce(Master),
    State;
carry_out_one({resend_after, N}, State) ->
    start_timer({resend, N}, ?RESEND_MS, State);
carry_out_one({timer_start, Timer, Ms}, State) ->
    start_timer({timer, Timer}, Ms, State);
carry_out_one({timer_cancel, Timer}, #state{timers = Timers} = State) ->
    case Timers of
        #{{timer, Timer} := Ref} ->
            _ = erlang:cancel_timer(Ref, [{async, true}, {info, false}]);
        #{} ->
            ok
    end,
    State#state{timers = maps:remove({timer, Timer}, Timers)};
carry_out_one(give_up_name, State) ->
    %% A drain gives the name up as it is answered, so a second halt goes
    %% straight on; a drain answered after it finds the name already gone.
    _ = whereis(?NAME) =:= self() andalso unregister(?NAME),
    State.

%% A timer whose message carries the event it delivers to the core, taken
%% only with the reference held here.
start_timer(Event, Ms, #state{timers = Timers} = State) ->
    State#state{timers = Timers#{Event => erlang:start_timer(Ms, self(), Event)}}.
