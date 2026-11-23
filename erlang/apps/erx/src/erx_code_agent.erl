%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_agent).

-moduledoc """
The code server of a domain (docs/design-live.md, "The code server"): the one process
through which the system domain's code service, erx_code, loads code into this domain.
It is not OTP's code_server, which it loads through. `kernel_sup` starts it as a
permanent child after `kernel_safe_sup`, and `kernel_sup`'s intensity is 0, so its end,
whatever the reason, is the domain's end (edit 41 of docs/design-runtime.md).

At its start it compares its runtime's limits with the code protocol's floors and fails
its start when one is below its floor, then names itself to its domain pid with
`{erx_code_agent, self()}`, whose encoding hands it to the system domain with `send`. In
a domain whose boot information carries `supervised` it returns from its start only once
its start load has loaded and erx_code has confirmed it, so every application after
`kernel` starts over the published overlay; in any other domain it returns at once.

It is a gen_statem in one of two states: `idle`, ready to take a load, and `loading`,
with a load in flight whose deadline is the state's timeout. A load that arrives while
another is in flight is postponed until the server is idle again. The decisions are
erx_code_agent_core's; this module applies their effects: sends, loads, the lifeline's
monitor, the start's acknowledgement and the stop. It takes erx_code's messages only in
the system domain's envelope, `{erx_origin, SystemId, Msg}`, and drops every other
message, counting it in its state (`sys:get_state/1`).

It is started by proc_lib and enters gen_statem's loop with `gen_statem:enter_loop/5`,
so that a supervised domain's start is acknowledged only after its start load; it has
no `init/1` and declares no behaviour. No frame of this module's code stays on the stack
between events: enter/1 enters the loop with a tail call, gen_statem enters each
callback through an external call, and the state holds no fun. So a load that replaces
this module or erx_code_batch leaves the server running: by the time a later load
purges the old code, the server is not running any of it.

A crash report shows the server's state without the core or the postponed loads, which
carry module bytes and manifests (format_status/1).
""".

-export([start_link/0, start_link/1]).
-export([enter/1, callback_mode/0, handle_event/4, format_status/1]).
-export_type([env/0]).

-include("generated/erx_abi.hrl").

-doc """
What the server knows of its domain: the system domain's id, the domain pid, whether the
boot information carries `supervised`, the runtime's limits and the code protocol's floors
(erx_code_agent_core:floor_check/2), the module that reads the domain's release, if any,
and how long a load may take in milliseconds, `code_load_wait` unless a test shortens it.

A release module exports `lookup(Hash) -> {ok, Bytes} | none`, the blob its release
manifest lists under Hash, and `hash(Module) -> {ok, Hash} | none`, the hash its manifest
gives a module of the release.
""".
-type env() :: #{system := pos_integer(), domain_pid := pid(), supervised := boolean(),
                 limits := erx_code_agent_core:limits(), floors := #{atom() => non_neg_integer()},
                 release => module() | none, wait => pos_integer()}.

%% The domain, the core, and how many messages the server dropped.
-type data() :: #{env := env(), core := erx_code_agent_core:core(), dropped := non_neg_integer()}.

-type state() :: idle | loading.

-doc """
Starts the code server of the domain this runtime is; `ignore` in the system domain,
whose boot page names no domain pid and which loads only through erx_code's own install
path, and in a runtime that is not erXos's.
""".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    case erlang:system_info(os_type) of
        {unix, erxos} ->
            case erx_dist:boot() of
                {_Self, {SystemId, _SystemNode, DomainPid}} when is_pid(DomainPid) ->
                    start_link(erxos_env(SystemId, DomainPid));
                _ ->
                    ignore
            end;
        _ ->
            ignore
    end.

-doc "Starts a code server in the domain Env describes.".
-spec start_link(env()) -> {ok, pid()} | {error, term()}.
start_link(Env) ->
    proc_lib:start_link(?MODULE, enter, [Env], infinity).

%% The runtime does not yet report its limits (erx:limits/0), the code protocol's floors
%% are not yet generated into abi/services/code.txt, and the boot information carries no
%% supervised flag, so no domain on erXos is supervised and its floor check is unknown
%% (TODO.md).
erxos_env(SystemId, DomainPid) ->
    #{system => SystemId, domain_pid => DomainPid, supervised => false,
      limits => unknown, floors => #{}}.

-doc false.
enter(Env) ->
    case erx_code_agent_core:floor_check(maps:get(limits, Env), maps:get(floors, Env)) of
        {below, Limit, Value, Floor} ->
            logger:error("erx_code_agent: ~s is ~b, below the code protocol's floor of ~b", [Limit, Value, Floor]),
            proc_lib:init_fail({error, {below_floor, Limit}}, {exit, normal});
        unknown ->
            logger:notice("erx_code_agent: the runtime's limits are unknown; the code protocol's floors are not checked"),
            serve(Env);
        ok ->
            serve(Env)
    end.

%% The start's acknowledgement is the core's `started` effect, now in any other domain
%% and after the confirmed start load in a supervised one. The loop is entered with a tail
%% call, so no frame of this module stays below it.
serve(Env) ->
    maps:get(domain_pid, Env) ! {erx_code_agent, self()},
    {Core, Effects} = erx_code_agent_core:new(maps:get(supervised, Env)),
    {Data, Actions} = effects(Effects, #{env => Env, core => Core, dropped => 0}),
    gen_statem:enter_loop(?MODULE, [], idle, Data, Actions).

-doc false.
callback_mode() ->
    handle_event_function.

-doc false.
-spec handle_event(gen_statem:event_type(), term(), state(), data()) ->
          gen_statem:event_handler_result(state(), data()).
handle_event(state_timeout, deadline, loading, Data) ->
    step(timeout, Data, []);
handle_event(internal, {loaded, Result}, loading, Data) ->
    step({loaded, Result}, Data, []);
handle_event(info, Message, loading, #{core := Core} = Data) ->
    case erlang:monotonic_time(millisecond) >= erx_code_agent_core:deadline(Core) of
        true ->
            %% Past the deadline: the load ends before any message still queued for it,
            %% which is handled again in the state the end leads to.
            step(timeout, Data, [postpone]);
        false ->
            message(Message, loading, Data)
    end;
handle_event(info, Message, idle, Data) ->
    message(Message, idle, Data);
handle_event(_Type, _Content, _State, Data) ->
    dropped(Data).

message({erx_origin, SystemId, Message}, State, #{env := #{system := SystemId}} = Data) ->
    from_system(Message, State, Data);
message({'DOWN', Monitor, process, _Pid, _Reason}, _State, Data) ->
    step({down, Monitor}, Data, []);
message(_Message, _State, Data) ->
    dropped(Data).

from_system({erx_code_load, Alias, _Manifest}, loading, _Data) when is_reference(Alias) ->
    {keep_state_and_data, [postpone]};
from_system({erx_code_load, Alias, Manifest}, idle, Data) when is_reference(Alias) ->
    take(Alias, Manifest, Data);
from_system({erx_code_piece, Alias, Hash, Offset, Bytes}, _State, Data)
  when is_reference(Alias), is_binary(Hash), is_integer(Offset), is_binary(Bytes) ->
    step({piece, Alias, Hash, Offset, Bytes}, Data, []);
from_system({erx_code_published, Alias, Lifeline}, _State, Data) when is_reference(Alias), is_pid(Lifeline) ->
    step({published, Alias, Lifeline}, Data, []);
from_system(_Message, _State, Data) ->
    dropped(Data).

dropped(#{dropped := Dropped} = Data) ->
    {keep_state, Data#{dropped := Dropped + 1}}.

%% Step 1's facts from the runtime: which modules are current and which blobs the release
%% holds. A name with no atom yet names no loaded module, so no atom is made for it.
take(Alias, Manifest, #{env := Env} = Data) ->
    Release = maps:get(release, Env, none),
    Deadline = erlang:monotonic_time(millisecond) + maps:get(wait, Env, ?ERX_CODE_LOAD_WAIT),
    case erx_code_agent_core:is_manifest(Manifest) of
        true ->
            Plan = [{Name, Hash, Size, source(Name, Hash, Release)} || {Name, Hash, Size} <- Manifest],
            step({take, Alias, Plan, Deadline}, Data, []);
        false ->
            dropped(Data)
    end.

source(Name, Hash, Release) ->
    case current_hash(Name, Release) of
        Hash -> current;
        _ -> released(Hash, Release)
    end.

released(_Hash, none) -> fetch;
released(Hash, Release) ->
    case Release:lookup(Hash) of
        {ok, Bytes} -> {release, Bytes};
        none -> fetch
    end.

%% A hot-loaded module's current hash is its file name (erx_code_batch:file_name/1); a
%% release module's is its release manifest's entry.
current_hash(Name, Release) ->
    try binary_to_existing_atom(Name) of
        Module ->
            case code:is_loaded(Module) of
                {file, File} when is_list(File) -> file_hash(filename:basename(File), Module, Release);
                _ -> none
            end
    catch
        error:badarg -> none
    end.

file_hash(Base, Module, Release) ->
    case string:split(Base, ".beam", trailing) of
        [Hex, ""] when length(Hex) =:= 64 ->
            try binary:decode_hex(list_to_binary(Hex)) catch error:badarg -> none end;
        _ when Release =/= none ->
            case Release:hash(Module) of
                {ok, Hash} -> Hash;
                none -> none
            end;
        _ ->
            none
    end.

%% One event through the core and its effects, then the state the core is in: `loading`,
%% with its deadline as the state's timeout, while a load is in flight, else `idle`.
step(Event, #{core := Core} = Data, Postpone) ->
    case erx_code_agent_core:step(Core, Event) of
        {stop, Reason, Effects} ->
            {Last, []} = effects(Effects, Data),
            {stop, Reason, Last};
        {Next, Effects} ->
            {Applied, Actions} = effects(Effects, Data#{core := Next}),
            case erx_code_agent_core:deadline(Next) of
                infinity -> {next_state, idle, Applied, Postpone ++ Actions};
                Deadline -> {next_state, loading, Applied,
                             [{state_timeout, Deadline, deadline, [{abs, true}]} | Postpone ++ Actions]}
            end
    end.

%% The effects in order, and the gen_statem actions they lead to: a batch load's result
%% is the next event the core takes, before any message.
effects(Effects, Data) ->
    lists:foldl(fun effect/2, {Data, []}, Effects).

effect({send, Alias, Message}, Acc) ->
    Alias ! Message,
    Acc;
effect({load_batch, Batch}, {Data, Actions}) ->
    {Data, Actions ++ [{next_event, internal, {loaded, erx_code_batch:load(Batch)}}]};
effect({monitor, Lifeline}, {#{core := Core} = Data, Actions}) ->
    {Data#{core := erx_code_agent_core:monitoring(Core, erlang:monitor(process, Lifeline))}, Actions};
effect(started, Acc) ->
    proc_lib:init_ack({ok, self()}),
    Acc;
effect(dropped, {#{dropped := Dropped} = Data, Actions}) ->
    {Data#{dropped := Dropped + 1}, Actions}.

-doc false.
format_status(Status) ->
    erx_report:status(Status, #{data => fun(Data) -> maps:remove(core, Data) end}).
