%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_state_file).
-moduledoc """
The development builds' store behind the store's seam (docs/design-bluetooth.md, "Bonds
and the store"): files in the Bluetooth domain's directory on the data partition, one
per generation, so a put that completes late never replaces a newer state.

**A file per generation.** `put/3` writes `bonds.N.new` for the generation `N` the store
names, created exclusively, synced, and renamed to `bonds.N`, as the SSH domain keeps its
host key before the vault (docs/design-ssh.md, "Host keys"); once `bonds.N` is in place
it deletes every name of a lower generation. `get/1` answers the newest file, `bonds.N`
of the highest `N`, and the highest generation any name carries, `.new` included. So a
put of an older generation that lands after a newer one, from a request the storage
domain completed after the store's deadline, lands below it and is never read; and since
a put renames only after its `.new` name has answered, every name a put may still rename
into place is counted by every listing made after the put's process has ended.

The answers are the seam's:

- `get/1`: `{ok, Generation, Blob}`, at most one octet past `bt_state_max` read, so an
  oversized file reaches `erx_bt_state` as a blob it refuses; `{ok, Generation, none}`
  when no `bonds.N` exists and the directory or the volume it lies in does; `{ok,
  Generation, <<>>}`, which does not decode, when the newest file cannot be read;
  `{error, unavailable}` otherwise, so a volume not mounted is never read as a store
  without bonds;
- `put/3`: `ok` once `bonds.N` is in place; `{error, unavailable}` when any step fails,
  the `.new` file then deleted.

A name that is not `bonds.N` or `bonds.N.new`, with `N` a positive decimal of at most 18
digits without a leading zero, is not the store's and is left alone (`generation/1`). The directory is
made 0700 and each file 0600 before any byte is written, where the file system keeps
modes.
""".

-include("generated/erx_abi.hrl").

-export([get/1, put/3, generation/1]).
-export_type([generation/0]).

-doc "A put's generation; `0` is the store before its first put.".
-type generation() :: non_neg_integer().

-doc "The newest blob kept in `Dir` and the highest generation named there.".
-spec get(file:filename()) -> {ok, generation(), binary() | none} | {error, unavailable}.
get(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            Named = [Generation || Name <- Names, {_, _} = Generation <- [generation(Name)]],
            Highest = lists:max([0 | [N || {_, N} <- Named]]),
            case [N || {state, N} <- Named] of
                [] -> {ok, Highest, none};
                Kept -> newest(filename:join(Dir, name(state, lists:max(Kept))), Highest)
            end;
        {error, enoent} ->
            case filelib:is_dir(filename:dirname(Dir)) of
                true -> {ok, 0, none};
                false -> {error, unavailable}
            end;
        {error, _} ->
            {error, unavailable}
    end.

%% A newest file that cannot be opened or read answers as an empty blob, which does not
%% decode: the store then runs unreadable, and `forget all` gets past it under the
%% generation the listing gave.
newest(Path, Highest) ->
    case file:open(Path, [read, binary]) of
        {ok, Device} ->
            Read = file:read(Device, ?ERX_BT_STATE_MAX + 1),
            _ = file:close(Device),
            case Read of
                {ok, Blob} -> {ok, Highest, Blob};
                _EofOrError -> {ok, Highest, <<>>}
            end;
        {error, _} ->
            {ok, Highest, <<>>}
    end.

-doc "Keeps `Blob` in `Dir` as generation `Generation`, above every lower one.".
-spec put(file:filename(), pos_integer(), binary()) -> ok | {error, unavailable}.
put(Dir, Generation, Blob) ->
    New = filename:join(Dir, name(new, Generation)),
    maybe
        ok ?= owner_only_dir(Dir),
        ok ?= write_owner_only(New, Blob),
        ok ?= file:rename(New, filename:join(Dir, name(state, Generation))),
        delete_below(Dir, Generation)
    else
        {error, eexist} ->
            {error, unavailable};
        {error, _} ->
            _ = file:delete(New),
            {error, unavailable}
    end.

%% Only once a higher `bonds.N` is in place; a name that will not go stays, harmless, as
%% it is below the newest.
delete_below(Dir, Generation) ->
    Names = case file:list_dir(Dir) of
                {ok, Listed} -> Listed;
                {error, _} -> []
            end,
    Lower = [Name || Name <- Names, {_, N} <- [generation(Name)], N < Generation],
    lists:foreach(fun(Name) -> file:delete(filename:join(Dir, Name)) end, Lower).

-doc """
The generation a directory entry's name carries, `{state, N}` for `bonds.N` and `{new,
N}` for `bonds.N.new`, or `other`. The name is untrusted, as anything read from a
medium is: only a positive decimal of at most 18 digits without a leading zero is a
generation, so each generation has one name and a planted one leaves the next put's
name short.
""".
-spec generation(term()) -> {state | new, pos_integer()} | other.
generation("bonds." ++ Rest) ->
    case lists:splitwith(fun(C) -> is_integer(C) andalso C >= $0 andalso C =< $9 end, Rest) of
        {[First | _] = Digits, Suffix} when First =/= $0, length(Digits) =< 18 -> suffix(Suffix, list_to_integer(Digits));
        _ -> other
    end;
generation(_Name) ->
    other.

suffix("", N) -> {state, N};
suffix(".new", N) -> {new, N};
suffix(_Suffix, _N) -> other.

name(state, N) -> "bonds." ++ integer_to_list(N);
name(new, N) -> name(state, N) ++ ".new".

owner_only_dir(Dir) ->
    case file:make_dir(Dir) of
        Made when Made =:= ok; Made =:= {error, eexist} -> kept_modes(file:change_mode(Dir, 8#700));
        {error, _} = Error -> Error
    end.

%% Created exclusively, so no other put's file is written into; closed whatever happens,
%% and the first error is the answer.
write_owner_only(Path, Blob) ->
    maybe
        {ok, Device} ?= file:open(Path, [write, binary, exclusive]),
        Written = maybe
                      ok ?= kept_modes(file:change_mode(Path, 8#600)),
                      ok ?= file:write(Device, Blob),
                      file:sync(Device)
                  end,
        Closed = file:close(Device),
        ok ?= Written,
        Closed
    end.

%% A file server that keeps no modes may refuse a change of them with enotsup; its
%% files have no modes to narrow.
kept_modes({error, enotsup}) -> ok;
kept_modes(Result) -> Result.
