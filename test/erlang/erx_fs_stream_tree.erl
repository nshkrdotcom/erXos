%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_stream_tree).
-moduledoc """
A test tree of one stream file, `s`, for the waiting-request tests of
docs/design-files.md ("Verification and testing", "Waiting requests").

A read of `s` waits for bytes: its callback answers `{wait, Keeper, {read,
Count}}`, and the tree's keeper, a process the test starts with
`start_keeper/0` and passes as the tree's `init/1` argument, holds the read
in an `erx_fs_waits` set until the test hands it bytes with `hand/2`. Each
read, oldest first, takes up to its count of the bytes held. A write is
answered at once and keeps nothing, as a line's output does, so only the
bytes the test hands answer a read.
""".

-behaviour(erx_fs).

-include("erx_fs_waits.hrl").

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1,
         clunk/2, write/4, unlink/4]).
-export([start_keeper/0, hand/2, held/1, log/1]).

-define(TREE, <<"test">>).
-define(ROOT_QID, {16#80, 0, 1}).
-define(STREAM_QID, {0, 0, 2}).

-doc "A keeper with no requests and no bytes, linked to the caller.".
start_keeper() ->
    spawn_link(fun() -> keep(erx_fs_waits:new(), <<>>, []) end).

-doc "Hands the keeper bytes for the reads it holds.".
hand(Keeper, Bytes) ->
    Keeper ! {bytes, Bytes},
    ok.

-doc "The requests the keeper holds, as erx_fs_waits:list/1 shows them.".
held(Keeper) ->
    ask(Keeper, held).

-doc """
What reached the keeper, oldest first: `{clunk, Held}` for each clunk, with
the count of requests it held then, `unlink` for each unlink and `flushed`
for each flush its set took.
""".
log(Keeper) ->
    ask(Keeper, log).

init(Keeper) when is_pid(Keeper) ->
    {ok, Keeper}.

root(_) ->
    {ok, ?TREE, root, ?ROOT_QID}.

walk(root, <<"s">>, _) -> {ok, stream, ?STREAM_QID};
walk(_, _, _) -> {error, enoent}.

getattr(root, _) -> {ok, #{mode => 8#40755, size => 0}};
getattr(stream, _) -> {ok, #{mode => 8#100666, size => 0}}.

open(Node, _, _) ->
    {ok, {Node, make_ref()}}.

read({stream, _}, _Offset, Count, Keeper) ->
    {wait, Keeper, {read, Count}};
read(_, _, _, _) ->
    {error, eisdir}.

write({stream, _}, Offset, Data, _) ->
    {ok, byte_size(Data), Offset};
write(_, _, _, _) ->
    {error, eisdir}.

readdir(_, _, _, _) ->
    {ok, []}.

statfs(_) ->
    {ok, #{type => 0, bsize => 512, blocks => 0, bfree => 0, bavail => 0,
           files => 1, ffree => 0, fsid => 0, namelen => 255}}.

%% A clunk runs only once its keeper holds no request: one that runs while a
%% read of its fid still waits answers ebusy, so the case that clunks a fid
%% whose read waits sees it. The keeper logs it with the count it held.
clunk(_, Keeper) ->
    case ask(Keeper, clunk) of
        [] -> ok;
        [_ | _] -> {error, ebusy}
    end.

%% Unlinking `s` is logged at the keeper; the name stays, as no case walks
%% to it after.
unlink(root, <<"s">>, _, Keeper) ->
    ask(Keeper, unlink);
unlink(_, _, _, _) ->
    {error, enoent}.

ask(Keeper, What) ->
    Ref = make_ref(),
    Keeper ! {ask, What, self(), Ref},
    receive
        {Ref, Answer} -> Answer
    after 2000 ->
        erlang:error(no_keeper)
    end.

%% The keeper: every request it holds is in Waits, Bytes are the bytes the
%% test handed it that no read has taken yet, and Log the tree's calls and
%% the flushes that reached it, newest first.
keep(Waits, Bytes, Log) ->
    receive
        ?ERX_FS_WAIT(_, _) = Wait ->
            serve(erx_fs_waits:hold(Wait, Waits), Bytes, Log);
        {bytes, More} ->
            serve(Waits, <<Bytes/binary, More/binary>>, Log);
        {ask, held, From, Ref} ->
            From ! {Ref, erx_fs_waits:list(Waits)},
            keep(Waits, Bytes, Log);
        {ask, log, From, Ref} ->
            From ! {Ref, lists:reverse(Log)},
            keep(Waits, Bytes, Log);
        {ask, clunk, From, Ref} ->
            Held = erx_fs_waits:list(Waits),
            From ! {Ref, Held},
            keep(Waits, Bytes, [{clunk, length(Held)} | Log]);
        {ask, unlink, From, Ref} ->
            From ! {Ref, ok},
            keep(Waits, Bytes, [unlink | Log]);
        Message ->
            case erx_fs_waits:info(Message, Waits) of
                {flushed, Waits1} -> keep(Waits1, Bytes, [flushed | Log]);
                {dropped, Waits1} -> keep(Waits1, Bytes, Log);
                unknown -> keep(Waits, Bytes, Log)
            end
    end.

%% Answers the oldest held read from the bytes held, while there are both.
serve(Waits, <<>>, Log) ->
    keep(Waits, <<>>, Log);
serve(Waits, Bytes, Log) ->
    case erx_fs_waits:list(Waits) of
        [{Wait, {read, Count}, waiting} | _] ->
            Size = min(Count, byte_size(Bytes)),
            <<Taken:Size/binary, Rest/binary>> = Bytes,
            serve(erx_fs_waits:answer(Wait, {ok, Taken}, Waits), Rest, Log);
        [] ->
            keep(Waits, Bytes, Log)
    end.
