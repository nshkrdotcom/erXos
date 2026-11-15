%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_file_description).
-moduledoc """
A stand-in for erx_file_description in erx_prog_handler's tests, whose
stock emulator has no erXos prim_file: the namespace is the release slice
alone, and an open answers the handler at once with this stand-in's
answer, enoent, so no description runs.
""".

-export([table/0, open/6, read/3, write/3, pread/4, pwrite/4, seek/4, clunk/2]).

table() -> [#{point => [], provider => release, root => [], rights => ro}].

open(Slot, _Path, _Flags, _Mode, _Table, _Cwd) ->
    self() ! {erx_file_opened, Slot, {error, enoent}},
    self().

read(_Description, _Slot, _Count) -> ok.
write(_Description, _Slot, _Bytes) -> ok.
pread(_Description, _Slot, _Offset, _Count) -> ok.
pwrite(_Description, _Slot, _Offset, _Bytes) -> ok.
seek(_Description, _Slot, _Offset, _Whence) -> ok.
clunk(_Description, _Slot) -> ok.
