%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_hci).
-moduledoc """
The controller process (docs/design-bluetooth.md, "The controller process's effects"): a
loop around `erx_bt_hci_core`, started last in the controller group. It turns each message
into one input, reads the clock, steps the core and performs the actions in order; a stop
ends it, and the group's restart resets the line and the controller.

- **Configuration.** At its start it builds the core's configuration from owners that
  outlive the group: the connection limit, the name and the appearance from `erx_bt`'s
  application keys (the name by default the host part of the node name), the identity
  address from `erx_bt_store`, and the advertising data from `erx_bt_adv:data/1`. Then it
  steps `start`, whose one action is `line_reset`.
- **The line.** Items go to the writer, `erx_bt_line_tx`, whose answers, `written` and
  `line_ready`, are inputs. Stepping `line_ready` gives the reader, `erx_bt_line_rx`, its
  first acknowledgement; each read's bytes are appended to what the last split left, split
  with `erx_h4:split/1`, decoded with `erx_hci` and stepped packet by packet, and then
  acknowledged. A split error stops the process.
- **Links.** `link_up` starts a temporary `erx_bt_link` under `erx_bt_link_sup` with a fresh
  `Conn`, monitors it and maps the link's full name to it; `to_link` and `busy` go to the
  process a name maps to, and are dropped for a name that maps to none; `link_down` removes
  the name and ends its process. A link process that ends while its name is mapped is its
  disconnect: the name is removed and `{request, Name, {disconnect, 16#13}}` is stepped.
  Names are unique only within one run of the core, so names, never handles, are mapped,
  and every link is in the group, which ends with the core.
- **Time.** One wake-up timer, at the core's deadline, is only a hint: `expired` changes
  nothing before the deadline, so a stale or early wake-up costs one look.
""".
-behaviour(gen_server).

-export([start_link/0, facts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

%% Remote User Terminated Connection (bumble/hci.py, line 752): a link's end.
-define(LINK_ENDED, 16#13).

-record(hci, {
    core :: erx_bt_hci_core:core(),
    rest = <<>> :: binary(),                   % the incomplete packet the last split left
    links = #{} :: #{erx_bt_hci_core:link() => pid()},
    monitors = #{} :: #{reference() => erx_bt_hci_core:link()},
    timer = none :: none | {reference(), erx_bt_hci_core:time()},
    ready = none :: none | map()               % the bring-up's facts, for /proc/bt
}).

-doc "Starts the controller process, last in the controller group.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "For `/proc/bt`: the core's facts and the bring-up's, `none` before `ready`.".
-spec facts() -> #{core := map(), ready := none | map()}.
facts() ->
    gen_server:call(?MODULE, facts).

init([]) ->
    Core = erx_bt_hci_core:new(config()),
    steps([start], #hci{core = Core}).

%% The core's configuration (docs/design-bluetooth.md, "The controller process's effects",
%% "Configuration"). No GATT table exists yet, so no UUID is advertised.
config() ->
    Data = erx_bt_adv:data(#{uuids => [], name => name(), appearance => application:get_env(erx_bt, appearance, 0)}),
    Data#{connections => application:get_env(erx_bt, connections, 1), address => erx_bt_store:address(),
          patch => patch(application:get_env(erx_bt, patch))}.

%% The advertised name: the application key, else the host part of the node name.
name() ->
    case application:get_env(erx_bt, name) of
        {ok, Name} -> unicode:characters_to_binary(Name);
        undefined -> lists:last(binary:split(atom_to_binary(node()), <<"@">>))
    end.

%% The patch the row names, read whole by erx_bt_patch, with the manufacturer it applies
%% to; a file the reader refuses ends the process before the line is touched.
patch(undefined) ->
    none;
patch({ok, File}) ->
    {ok, Manufacturer} = application:get_env(erx_bt, patch_manufacturer),
    case erx_bt_patch:records(File) of
        {ok, Records} -> #{manufacturer => Manufacturer, records => Records};
        {error, Reason} -> exit({patch_refused, File, Reason})
    end.

handle_info({erx_bt_line_tx, Answer}, State) when Answer =:= written; Answer =:= line_ready ->
    step_noreply(Answer, State);
handle_info({erx_bt_line_rx, Bytes}, #hci{rest = Rest} = State) ->
    case erx_h4:split(<<Rest/binary, Bytes/binary>>) of
        {error, Reason} ->
            {stop, {h4, Reason}, State};
        {Packets, Left} ->
            case steps([input(Packet) || Packet <- Packets], State#hci{rest = Left}) of
                {ok, Stepped} ->
                    erx_bt_line_rx ! {read, self()},
                    {noreply, Stepped};
                {stop, Reason} ->
                    {stop, Reason, State}
            end
    end;
handle_info({erx_bt_link, Name, Request}, State) ->
    step_noreply({request, Name, Request}, State);
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, #hci{monitors = Monitors, links = Links} = State) ->
    case maps:take(Monitor, Monitors) of
        {Name, Rest} ->
            Ended = State#hci{monitors = Rest, links = maps:remove(Name, Links)},
            step_noreply({request, Name, {disconnect, ?LINK_ENDED}}, Ended);
        error ->
            {noreply, State}
    end;
handle_info({timeout, Timer, wake}, #hci{timer = {Timer, _Deadline}} = State) ->
    step_noreply(expired, State#hci{timer = none});
handle_info(_Message, State) ->
    {noreply, State}.

handle_call(facts, _From, #hci{core = Core, ready = Ready} = State) ->
    {reply, #{core => erx_bt_hci_core:facts(Core), ready => Ready}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% A crash report shows sizes, never a packet's or a peer's bytes: the last read and
%% the incomplete packet are untrusted, and from pairing on they may carry keys. The core
%% shows as its facts, since its plan holds the patch's records, the vendor's firmware.
format_status(#{state := #hci{core = Core, rest = Rest} = State} = Status) ->
    Shown = Status#{state := State#hci{core = {facts, erx_bt_hci_core:facts(Core)}, rest = {bytes, byte_size(Rest)}}},
    case Shown of
        #{message := {erx_bt_line_rx, Bytes}} -> Shown#{message := {erx_bt_line_rx, {bytes, byte_size(Bytes)}}};
        #{} -> Shown
    end;
format_status(Status) ->
    Status.

%% A packet from the controller as the core's input.
input({event, Code, Parameters}) -> {event, erx_hci:event(Code, Parameters)};
input({acl, Handle, Boundary, Broadcast, Data}) -> {acl, Handle, Boundary, Broadcast, Data}.

step_noreply(Input, State) ->
    case steps([Input], State) of
        {ok, Stepped} -> {noreply, Stepped};
        {stop, Reason} -> {stop, Reason, State}
    end.

%% Steps each input in order at the clock, performing its actions, then sets the wake-up
%% timer at the core's deadline.
steps([], State) ->
    {ok, wake_up(State)};
steps([Input | Inputs], #hci{core = Core} = State) ->
    case erx_bt_hci_core:step(Input, erlang:monotonic_time(millisecond), Core) of
        {ok, Actions, Next} ->
            steps(Inputs, lists:foldl(fun perform/2, after_input(Input, State#hci{core = Next}), Actions));
        {stop, Reason} ->
            {stop, Reason}
    end.

%% The line's reset answered: the reader's first acknowledgement.
after_input(line_ready, State) ->
    erx_bt_line_rx ! {read, self()},
    State;
after_input(_Input, State) ->
    State.

perform(line_reset, State) ->
    erx_bt_line_tx ! {line_reset, self()},
    State;
perform({write, Bytes}, State) ->
    erx_bt_line_tx ! {write, self(), Bytes},
    State;
perform({ready, Facts}, State) ->
    State#hci{ready = Facts};
perform({link_up, Name, Info}, #hci{links = Links, monitors = Monitors} = State) ->
    {ok, Pid} = erx_bt_link_sup:start_child(#{name => Name, conn => make_ref(), info => Info, hci => self()}),
    State#hci{links = Links#{Name => Pid}, monitors = Monitors#{monitor(process, Pid) => Name}};
perform({to_link, Name, Event}, State) ->
    to_link(Name, Event, State);
perform({busy, Name}, State) ->
    to_link(Name, busy, State);
perform({link_down, Name}, #hci{links = Links, monitors = Monitors} = State) ->
    case maps:take(Name, Links) of
        {Pid, Rest} ->
            [Monitor] = [M || M := N <- Monitors, N =:= Name],
            demonitor(Monitor, [flush]),
            _ = erx_bt_link_sup:stop_link(Pid),
            State#hci{links = Rest, monitors = maps:remove(Monitor, Monitors)};
        error ->
            State
    end.

%% An action for a name that maps to no process is dropped: its link has already ended.
to_link(Name, Event, #hci{links = Links} = State) ->
    case Links of
        #{Name := Pid} -> Pid ! {erx_bt_hci, Event};
        #{} -> ok
    end,
    State.

%% One timer, at the core's deadline; a timer at another deadline is cancelled.
wake_up(#hci{core = Core, timer = Timer} = State) ->
    case {erx_bt_hci_core:next_deadline(Core), Timer} of
        {Deadline, {_Ref, Deadline}} ->
            State;
        {Deadline, _} ->
            cancel(Timer),
            State#hci{timer = arm(Deadline)}
    end.

arm(infinity) -> none;
arm(Deadline) -> {erlang:start_timer(Deadline, self(), wake, [{abs, true}]), Deadline}.

cancel(none) -> ok;
cancel({Ref, _Deadline}) -> _ = erlang:cancel_timer(Ref), ok.
