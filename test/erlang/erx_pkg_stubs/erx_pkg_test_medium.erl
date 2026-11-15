%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_test_medium).
-moduledoc """
A simulated medium for erx_pkg_io's tests: the packages in a public ETS
table, `{{Place, File}, Bytes}`, with the listing's answer under `listing`
(the names are the installed files unless it is set), a failing deletion
under `fail_delete`, and every deletion logged under `deleted`.
""".
-behaviour(erx_pkg_io).

-export([new/0, put/3, set/2, deleted/0]).
-export([list/1, size/2, pread/4, delete/1]).

new() ->
    _ = [ets:delete(?MODULE) || ets:whereis(?MODULE) =/= undefined],
    ets:new(?MODULE, [named_table, public, ordered_set]),
    ets:insert(?MODULE, {deleted, []}),
    ok.

put(Place, File, Bytes) -> ets:insert(?MODULE, {{Place, File}, Bytes}), ok.
set(Key, Value) -> ets:insert(?MODULE, {Key, Value}), ok.
deleted() -> lists:reverse(ets:lookup_element(?MODULE, deleted, 2)).

list(Max) ->
    case ets:lookup(?MODULE, listing) of
        [{listing, Answer}] -> Answer;
        [] ->
            Names = [File || {{installed, File}, _} <- ets:tab2list(?MODULE)],
            {ok, lists:sublist(Names, Max), length(Names) > Max}
    end.

size(Place, File) ->
    case ets:lookup(?MODULE, {Place, File}) of
        [{_, Bytes}] -> {ok, byte_size(Bytes)};
        [] -> {error, enoent}
    end.

pread(Place, File, Offset, Size) ->
    case ets:lookup(?MODULE, {Place, File}) of
        [{_, Bytes}] when Offset =< byte_size(Bytes) ->
            {ok, binary:part(Bytes, Offset, min(Size, byte_size(Bytes) - Offset))};
        [{_, _}] -> {ok, <<>>};
        [] -> {error, enoent}
    end.

delete(File) ->
    case ets:lookup(?MODULE, fail_delete) of
        [{fail_delete, true}] ->
            {error, eio};
        _ ->
            ets:insert(?MODULE, {deleted, [File | ets:lookup_element(?MODULE, deleted, 2)]}),
            ets:delete(?MODULE, {installed, File}),
            ok
    end.
