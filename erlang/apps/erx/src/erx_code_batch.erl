%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_batch).

-moduledoc """
Makes a batch of modules current in this runtime as one step, or none of them
(docs/design-live.md, "The code server", step 3). The system domain's code
service, erx_code, loads its installs through it, and every other domain's code
server, erx_code_agent, its loads, so both routes refuse and purge alike.

`code:prepare_loading/1` checks every module of the batch, its name against its
bytes included, and `code:finish_loading/1`, the two halves of
`code:atomic_load/1`, makes the batch current or refuses it whole; a module with
an `-on_load` function is refused there as `on_load_not_allowed`. The last check
of `code:finish_loading/1` is that no module still has old code: only when every
refusal is that one is the old code of those modules purged, as stock's loads
purge it, and the batch finished again, so a batch refused for any other reason,
a sticky or pending module, purges nothing. Purging ends any process still
running a module's old code, as `code:load_binary/3` does. Each module's file
name, which `code:which/1` reports, is its blob's hash in hexadecimal, which is
how a later load tells that the module is already current.
""".

-export([load/1, file_name/1]).
-export_type([module_bytes/0, result/0]).

-doc "A module of a batch: its name, the SHA-256 of its bytes, and the bytes.".
-type module_bytes() :: {Name :: binary(), Hash :: <<_:256>>, Bytes :: binary()}.

-doc """
`ok` once every module of the batch is current, or `{error, {not_loaded, Failed}}`
with each refused module's name and the reason `code:atomic_load/1` gives.
""".
-type result() :: ok | {error, {not_loaded, [{binary(), atom()}]}}.

-doc "Makes every module of Batch current as one step, or none of them.".
-spec load([module_bytes()]) -> result().
load([]) ->
    ok;
load(Batch) ->
    Modules = [{binary_to_atom(Name), file_name(Hash), Bytes} || {Name, Hash, Bytes} <- Batch],
    case code:prepare_loading(Modules) of
        {ok, Prepared} -> finish(Prepared, purge_once);
        {error, Failed} -> not_loaded(Failed)
    end.

-doc "The file name a module loaded with hash Hash carries: the hash in hexadecimal.".
-spec file_name(<<_:256>>) -> string().
file_name(Hash) ->
    binary_to_list(binary:encode_hex(Hash, lowercase)) ++ ".beam".

%% A batch refused only because some of its modules still have old code is finished again
%% once that old code is purged; a batch refused for anything else purges nothing.
finish(Prepared, Purge) ->
    case {code:finish_loading(Prepared), Purge} of
        {ok, _} ->
            ok;
        {{error, Failed}, purge_once} ->
            case lists:all(fun({_Module, What}) -> What =:= not_purged end, Failed) of
                true ->
                    lists:foreach(fun({Module, not_purged}) -> code:purge(Module) end, Failed),
                    finish(Prepared, purged);
                false ->
                    not_loaded(Failed)
            end;
        {{error, Failed}, purged} ->
            not_loaded(Failed)
    end.

not_loaded(Failed) ->
    {error, {not_loaded, [{atom_to_binary(Module), What} || {Module, What} <- Failed]}}.
