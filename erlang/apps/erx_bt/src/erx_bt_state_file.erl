%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_state_file).
-moduledoc """
The development builds' store behind the store's seam (docs/design-bluetooth.md, "Bonds
and the store"): the file `state` in the Bluetooth domain's directory on the data
partition, replaced whole by write, sync and rename, as the SSH domain keeps its host key
before the vault (docs/design-ssh.md, "Host keys"). It answers exactly the seam's
results:

- `get/1`: `{ok, Blob}`, at most one octet past `bt_state_max` read, so an oversized file
  reaches `erx_bt_state` as a blob it refuses; `none` when the file does not exist and
  the directory or the volume it lies in does; `{error, unavailable}` otherwise, so a
  volume not mounted is never read as a store without bonds;
- `put/2`: `ok` once the new file is synced and renamed into place; `{error,
  unavailable}` when any step fails, the new file then deleted.

The directory is made 0700 and the file 0600 before any byte is written, where the file
system keeps modes.
""".

-include("generated/erx_abi.hrl").

-export([get/1, put/2]).

-define(STATE_FILE, "state").

-doc "The blob kept in `Dir`, or `none`, or `{error, unavailable}`.".
-spec get(file:filename()) -> {ok, binary()} | none | {error, unavailable}.
get(Dir) ->
    Path = filename:join(Dir, ?STATE_FILE),
    case file:open(Path, [read, binary]) of
        {ok, Device} ->
            Read = file:read(Device, ?ERX_BT_STATE_MAX + 1),
            _ = file:close(Device),
            case Read of
                {ok, Blob} -> {ok, Blob};
                eof -> {ok, <<>>};
                {error, _} -> {error, unavailable}
            end;
        {error, enoent} ->
            case directory(Dir) orelse directory(filename:dirname(Dir)) of
                true -> none;
                false -> {error, unavailable}
            end;
        {error, _} ->
            {error, unavailable}
    end.

directory(Path) -> filelib:is_dir(Path).

-doc "Replaces the file in `Dir` with `Blob` whole.".
-spec put(file:filename(), binary()) -> ok | {error, unavailable}.
put(Dir, Blob) ->
    Path = filename:join(Dir, ?STATE_FILE),
    New = Path ++ ".new." ++ integer_to_list(erlang:unique_integer([positive])),
    maybe
        ok ?= owner_only_dir(Dir),
        ok ?= write_owner_only(New, Blob),
        ok ?= file:rename(New, Path)
    else
        {error, _} ->
            _ = file:delete(New),
            {error, unavailable}
    end.

owner_only_dir(Dir) ->
    case file:make_dir(Dir) of
        Made when Made =:= ok; Made =:= {error, eexist} -> kept_modes(file:change_mode(Dir, 8#700));
        {error, _} = Error -> Error
    end.

%% The file is closed whatever happens, and the first error is the answer.
write_owner_only(Path, Blob) ->
    maybe
        {ok, Device} ?= file:open(Path, [write, binary]),
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
