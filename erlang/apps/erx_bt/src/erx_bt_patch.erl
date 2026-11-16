%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_patch).
-moduledoc """
The patch reader (docs/design-bluetooth.md, "The bring-up", step 4). A controller's RAM
patch, a `.hcd` file, is a run of HCI commands, each `opcode(2, little-endian) length(1)
payload`, which the bring-up replays one by one. The file's bytes are untrusted: the
reader takes the file whole before its first record is sent, accepts it only when it is
made of complete records of Write RAM (`0xFC4C`) and Launch RAM (`0xFC4E`), and refuses
any other whole, so a damaged file sends nothing rather than half a patch. A refusal
names the offset and, for a foreign opcode, the opcode, never the file's bytes.
""".

-export([records/1, parse/1]).
-export_type([patch_record/0, reason/0]).

-define(WRITE_RAM, 16#FC4C).
-define(LAUNCH_RAM, 16#FC4E).

-type patch_record() :: {?WRITE_RAM | ?LAUNCH_RAM, binary()}.
-type reason() :: empty | {truncated, non_neg_integer()} | {foreign_opcode, non_neg_integer(), 0..16#FFFF}.

-doc """
The records of `File`, a file of `erx_bt`'s `priv` directory as the application key
`patch` names it, in file order; or why the file cannot be read or is refused.
""".
-spec records(file:filename()) -> {ok, [patch_record(), ...]} | {error, reason() | file:posix()}.
records(File) ->
    case file:read_file(filename:join(code:priv_dir(erx_bt), File)) of
        {ok, Bytes} -> parse(Bytes);
        {error, Reason} -> {error, Reason}
    end.

-doc "The records of a patch file's bytes, in order, or why the file is refused.".
-spec parse(binary()) -> {ok, [patch_record(), ...]} | {error, reason()}.
parse(<<>>) ->
    {error, empty};
parse(Bytes) ->
    try
        {ok, parse(Bytes, 0, [])}
    catch
        throw:Reason -> {error, Reason}
    end.

%% Offset is where the record at the head of the bytes starts in the file.
parse(<<>>, _Offset, Records) ->
    lists:reverse(Records);
parse(<<Opcode:16/little, Length, Payload:Length/binary, Rest/binary>>, Offset, Records)
  when Opcode =:= ?WRITE_RAM; Opcode =:= ?LAUNCH_RAM ->
    parse(Rest, Offset + 3 + Length, [{Opcode, Payload} | Records]);
parse(<<Opcode:16/little, _/binary>>, Offset, _Records) when Opcode =/= ?WRITE_RAM, Opcode =/= ?LAUNCH_RAM ->
    throw({foreign_opcode, Offset, Opcode});
parse(_Bytes, Offset, _Records) ->
    throw({truncated, Offset}).
