%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_input_follower).
-moduledoc """
The display's follower of its input grants (docs/design-display.md, "The
display device"): one supervised process that keeps one erx_input_reader
running for each file of each input tree the domain is granted, a tree of
another domain's service of the `input` interface (abi/services/input.txt),
such as the USB domain's HID devices.

It looks once a second, the first time as it starts, at the domain's grants
of the input interface (erx:granted/1). Those names arrive with the
domain's ready answer, after the display's applications start, so a first
look that finds none is normal. For each name it does not yet follow whose
facet is installed it resolves the grant once (erx_facets:file_grant/3,
read-only, on the tree every input service serves, `input_tree`), monitors the grant's process, and lists the tree in a linked
lister process (erx_input_reader:files/1), so a tree whose server is slow
to answer holds up no other tree. With the listing it starts one reader,
linked to it, for each file, on that same grant, named `Facet/File` to
the router.

When the grant's process ends, the follower stops that tree's lister or
readers and waits for each to end before it does anything else, so no
reader of the old grant runs beside a replacement (the router keys each
source by its pid, so it releases an old reader's keys whenever its monitor
fires), and forgets the tree: the next look resolves its name again, and finds the
server's new grant once the domain service has installed it. A listing
that fails, or a lister that ends without one, also forgets the tree, to be looked at again. A reader that
ends by itself, at its file's end or a failed read, is not replaced: only
a new grant starts new readers. The follower traps exits, so a reader's
end never ends it, and stops every reader as it terminates.

Its effects come as an environment (env/0), so a host test drives it over
model grants and readers.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([env/0]).

-include("generated/erx_abi.hrl").

-doc """
What the follower acts through: `granted`, the names of the domain's input
grants; `resolve`, a name's grant, or an error while its facet is not
installed; `list`, a tree's files; `start`, one reader of a file, by its
device name, grant and file name, linked to the caller; and `look_ms`, the
time between looks.
""".
-type env() :: #{granted := fun(() -> [atom()]),
                 resolve := fun((atom()) -> {ok, erx_input_reader:grant()} | {error, term()}),
                 list := fun((erx_input_reader:grant()) -> {ok, [binary()]} | {error, term()}),
                 start := fun((binary(), erx_input_reader:grant(), binary()) -> pid()),
                 look_ms := pos_integer()}.

%% A followed tree: the monitor on its grant's process, the grant, and its lister while
%% the tree is listed or its live readers once it is.
-type tree() :: #{monitor := reference(), grant := erx_input_reader:grant(),
                  phase := {listing, pid()} | {reading, [pid()]}}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{granted => fun() -> erx:granted(?ERX_SERVICE_INPUT) end,
                 resolve => fun(Name) -> erx_facets:file_grant(Name, ro, ?ERX_INPUT_TREE_BYTES) end,
                 list => fun erx_input_reader:files/1,
                 start => fun(Device, Grant, File) ->
                                  erx_input_reader:start_link(Device, erx_input_reader:opener(Grant, File))
                          end,
                 look_ms => 1000}).

-doc "The follower over Env, for a host test.".
-spec start_link(env()) -> {ok, pid()} | {error, term()}.
start_link(Env) ->
    gen_server:start_link(?MODULE, Env, []).

init(Env) ->
    process_flag(trap_exit, true),
    self() ! look,
    {ok, #{env => Env, trees => #{}}}.

handle_call(_Request, _From, State) ->
    {reply, {error, enotsup}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(look, #{env := #{granted := Granted, look_ms := Ms}} = State) ->
    _ = erlang:send_after(Ms, self(), look),
    {noreply, lists:foldl(fun follow/2, State, Granted())};
handle_info({listed, Lister, Listing}, State) ->
    {noreply, on_tree(fun(#{phase := Phase}) -> Phase =:= {listing, Lister} end,
                      fun(Name, Tree, S) -> listed(Name, Tree, Listing, S) end, State)};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    {noreply, on_tree(fun(#{monitor := M}) -> M =:= Monitor end, fun(Name, _Tree, S) -> unfollow(Name, S) end, State)};
handle_info({'EXIT', Pid, Reason}, State) ->
    %% A lister's listing comes before its exit, since both are its signals to the
    %% follower, so a lister that ends while its tree is still listed failed to list it.
    Listed = on_tree(fun(#{phase := Phase}) -> Phase =:= {listing, Pid} end,
                     fun(Name, Tree, S) -> listed(Name, Tree, {error, {lister, Reason}}, S) end, State),
    {noreply, on_tree(fun(#{phase := Phase}) -> reads(Pid, Phase) end, fun(Name, Tree, S) -> reader_ended(Name, Tree, Pid, S) end,
                      Listed)};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #{trees := Trees}) ->
    maps:foreach(fun(_Name, #{phase := Phase}) -> stop(Phase) end, Trees).

%% Follows the tree Name when it is not followed yet and its facet is installed: its grant,
%% resolved once, monitored, and listed in a lister linked to the follower.
follow(Name, #{trees := Trees} = State) when is_map_key(Name, Trees) ->
    State;
follow(Name, #{env := #{resolve := Resolve, list := List}, trees := Trees} = State) ->
    case Resolve(Name) of
        {ok, {Server, _Tree, ro} = Grant} ->
            Monitor = erlang:monitor(process, Server),
            Follower = self(),
            Lister = spawn_link(fun() -> Follower ! {listed, self(), List(Grant)} end),
            State#{trees := Trees#{Name => #{monitor => Monitor, grant => Grant, phase => {listing, Lister}}}};
        {error, _} ->
            State
    end.

%% The tree Name listed: one reader for each file, on the tree's grant, or with a failed
%% listing, the tree forgotten until the next look.
-spec listed(atom(), tree(), {ok, [binary()]} | {error, term()}, State) -> State when State :: map().
listed(Name, #{grant := Grant} = Tree, {ok, Files}, #{env := #{start := Start}, trees := Trees} = State) ->
    Prefix = <<(atom_to_binary(Name))/binary, $/>>,
    Readers = [Start(<<Prefix/binary, File/binary>>, Grant, File) || File <- Files],
    State#{trees := Trees#{Name := Tree#{phase := {reading, Readers}}}};
listed(Name, #{monitor := Monitor}, {error, Reason}, #{trees := Trees} = State) ->
    _ = erx_log:debug_text(["erx_input_follower: ", atom_to_binary(Name), " not listed: ",
                            io_lib:format("~0p", [Reason])]),
    true = erlang:demonitor(Monitor, [flush]),
    State#{trees := maps:remove(Name, Trees)}.

%% The reader Pid of the tree Name ended by itself, at its file's end or a failed read: it
%% is not replaced, and no longer stopped with its tree.
reader_ended(Name, #{phase := {reading, Readers}} = Tree, Pid, #{trees := Trees} = State) ->
    State#{trees := Trees#{Name := Tree#{phase := {reading, lists:delete(Pid, Readers)}}}}.

%% The tree Name's grant ended: its lister or readers stopped, and the tree forgotten.
unfollow(Name, #{trees := Trees} = State) ->
    #{phase := Phase} = maps:get(Name, Trees),
    stop(Phase),
    State#{trees := maps:remove(Name, Trees)}.

%% Stops the processes of a tree's phase and returns once each has ended: each is linked
%% to the follower and its exit has not been taken, since a taken exit removes a reader
%% from its tree and a lister's tree from the follower, so exactly one exit message comes.
stop({listing, Lister}) -> stop_all([Lister]);
stop({reading, Readers}) -> stop_all(Readers).

stop_all(Pids) ->
    lists:foreach(fun(Pid) -> exit(Pid, shutdown) end, Pids),
    lists:foreach(fun(Pid) -> receive {'EXIT', Pid, _} -> ok end end, Pids).

reads(Pid, {reading, Readers}) -> lists:member(Pid, Readers);
reads(_Pid, {listing, _Lister}) -> false.

%% Applies Fun to the one followed tree Match picks, by its name, or leaves State as it is
%% when none does, as for a message about a tree already forgotten.
on_tree(Match, Fun, #{trees := Trees} = State) ->
    case [{Name, Tree} || Name := Tree <- Trees, Match(Tree)] of
        [{Name, Tree}] -> Fun(Name, Tree, State);
        [] -> State
    end.
