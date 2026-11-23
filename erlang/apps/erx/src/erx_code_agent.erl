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

The decisions are erx_code_agent_core's; this module applies their effects: sends,
loads, the lifeline's monitor and the exit. It takes erx_code's messages only in the
system domain's envelope, `{erx_origin, SystemId, Msg}`, and drops and counts every
other message. A load that arrives while another is in flight waits in the mailbox.

Each message is entered through an external call, `?MODULE:loop/1`, as a gen_server
enters its callbacks, so a load that replaces this module or erx_code_batch leaves the
server running: by the time a later load purges the old code, the server is not running
any of it. The state holds no fun for the same reason.
""".

-export([start_link/0, start_link/1]).
-export([init/2, loop/1]).
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
    proc_lib:start_link(?MODULE, init, [self(), Env], infinity).

%% The runtime does not yet report its limits (erx:limits/0), the code protocol's floors
%% are not yet generated into abi/services/code.txt, and the boot information carries no
%% supervised flag, so no domain on erXos is supervised and its floor check is unknown
%% (TODO.md).
erxos_env(SystemId, DomainPid) ->
    #{system => SystemId, domain_pid => DomainPid, supervised => false,
      limits => unknown, floors => #{}}.

-doc false.
init(Parent, Env) ->
    case erx_code_agent_core:floor_check(maps:get(limits, Env), maps:get(floors, Env)) of
        {below, Limit, Value, Floor} ->
            logger:error("erx_code_agent: ~s is ~b, below the code protocol's floor of ~b", [Limit, Value, Floor]),
            proc_lib:init_fail({error, {below_floor, Limit}}, {exit, normal});
        unknown ->
            logger:notice("erx_code_agent: the runtime's limits are unknown; the code protocol's floors are not checked"),
            serve(Parent, Env);
        ok ->
            serve(Parent, Env)
    end.

serve(Parent, Env) ->
    begin
            put(dropped, 0),
            maps:get(domain_pid, Env) ! {erx_code_agent, self()},
            {Core, Effects} = erx_code_agent_core:new(maps:get(supervised, Env)),
            loop(apply_effects(Effects, #{parent => Parent, env => Env, core => Core}))
    end.

-doc false.
-spec loop(map()) -> no_return().
loop(#{env := #{system := SystemId}, core := Core} = State) ->
    Idle = erx_code_agent_core:idle(Core),
    Lifeline = erx_code_agent_core:lifeline(Core),
    Next = case remaining(Core) of
        0 ->
            %% Past the deadline: the load ends before any message still queued for it.
            step(timeout, State);
        Wait -> receive
        {erx_origin, SystemId, {erx_code_load, Alias, Manifest}} when Idle, is_reference(Alias) ->
            take(Alias, Manifest, State);
        {erx_origin, SystemId, {erx_code_piece, Alias, Hash, Offset, Bytes}}
          when is_reference(Alias), is_binary(Hash), is_integer(Offset), is_binary(Bytes) ->
            step({piece, Alias, Hash, Offset, Bytes}, State);
        {erx_origin, SystemId, {erx_code_published, Alias, Lifeline1}} when is_reference(Alias), is_pid(Lifeline1) ->
            step({published, Alias, Lifeline1}, State);
        {'DOWN', Lifeline, process, _Pid, _Reason} ->
            step({down, Lifeline}, State);
        Other when Idle orelse not (is_tuple(Other) andalso tuple_size(Other) =:= 3
                                    andalso element(1, Other) =:= erx_origin
                                    andalso is_tuple(element(3, Other)) andalso tuple_size(element(3, Other)) =:= 3
                                    andalso element(1, element(3, Other)) =:= erx_code_load) ->
            %% A load waits in the mailbox while another is in flight; anything else
            %% of another origin or shape is dropped.
            apply_effects([dropped], State)
    after Wait ->
        step(timeout, State)
    end
    end,
    ?MODULE:loop(Next).

%% Step 1's facts from the runtime: which modules are current and which blobs the release
%% holds. A name with no atom yet names no loaded module, so no atom is made for it.
take(Alias, Manifest, #{env := Env} = State) ->
    Release = maps:get(release, Env, none),
    Deadline = erlang:monotonic_time(millisecond) + maps:get(wait, Env, ?ERX_CODE_LOAD_WAIT),
    case erx_code_agent_core:is_manifest(Manifest) of
        true ->
            Plan = [{Name, Hash, Size, source(Name, Hash, Release)} || {Name, Hash, Size} <- Manifest],
            step({take, Alias, Plan, Deadline}, State);
        false ->
            apply_effects([dropped], State)
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

step(Event, #{core := Core} = State) ->
    {Next, Effects} = erx_code_agent_core:step(Core, Event),
    apply_effects(Effects, State#{core := Next}).

apply_effects(Effects, State) ->
    lists:foldl(fun apply_effect/2, State, Effects).

apply_effect({send, Alias, Message}, State) ->
    Alias ! Message,
    State;
apply_effect({load_batch, Batch}, State) ->
    step({loaded, erx_code_batch:load(Batch)}, State);
apply_effect({monitor, Lifeline}, #{core := Core} = State) ->
    State#{core := erx_code_agent_core:monitoring(Core, erlang:monitor(process, Lifeline))};
apply_effect(started, #{parent := Parent} = State) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    State;
apply_effect(dropped, State) ->
    put(dropped, get(dropped) + 1),
    State;
apply_effect({exit, Reason}, _State) ->
    exit(Reason).

remaining(Core) ->
    case erx_code_agent_core:deadline(Core) of
        infinity -> infinity;
        Deadline -> max(0, Deadline - erlang:monotonic_time(millisecond))
    end.
