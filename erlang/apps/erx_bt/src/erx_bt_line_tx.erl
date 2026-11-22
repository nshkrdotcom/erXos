%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_line_tx).
-moduledoc """
The controller's writer (docs/design-bluetooth.md, "The controller process's effects"): it
opens the line's `data` and `ctl` at its start and carries out one item at a time, answering
the process that gave it:

- `{write, From, Bytes}`: writes `Bytes` to `data` and answers `{erx_bt_line_tx, written}`;
- `{line_reset, From}`: writes `reset` to `ctl`, which returns once the line has been reset,
  and answers `{erx_bt_line_tx, line_ready}`.

The controller process gives the next item only after the answer, and the reset only as the
bring-up's first step, so the writer holds one item at a time. A write that fails, `eio`
from either file included, ends the writer and so its group, whose restart is the recovery
for a broken line and a failed power notification alike. It does not trap exits, so the
group's shutdown ends it while it waits on the line.
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-include("generated/erx_abi.hrl").

-doc "Starts the writer, registered as `erx_bt_line_tx`; `Open` is `file:open/2` or a test's model.".
-spec start_link(erx_bt_host_sup:open()) -> gen_server:start_ret().
start_link(Open) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Open, []).

init(Open) ->
    maybe
        {ok, Data} ?= open(Open, data),
        {ok, Ctl} ?= open(Open, ctl),
        {ok, #{data => Data, ctl => Ctl}}
    else
        {error, Failed} -> {stop, Failed}
    end.

open(Open, File) ->
    case Open(<<"/line/", (atom_to_binary(File))/binary>>, [write, binary]) of
        {ok, Device} -> {ok, Device};
        {error, Reason} -> {error, {line_open, File, Reason}}
    end.

handle_info({write, From, Bytes}, #{data := Data} = Files) ->
    carry_out(From, written, file:write(Data, Bytes), Files);
handle_info({line_reset, From}, #{ctl := Ctl} = Files) ->
    carry_out(From, line_ready, file:write(Ctl, ?ERX_LINE_CTL_RESET_BYTES), Files);
handle_info(_Message, Files) ->
    {noreply, Files}.

carry_out(From, Answer, ok, Files) ->
    From ! {?MODULE, Answer},
    {noreply, Files};
carry_out(_From, Answer, Failed, Files) ->
    {stop, {line_write, Answer, Failed}, Files}.

handle_call(_Request, _From, Files) ->
    {reply, {error, unsupported}, Files}.

handle_cast(_Message, Files) ->
    {noreply, Files}.

%% A crash report shows a write's size, never its bytes: a command may carry a Long Term
%% Key, and a packet a peer's data or, from pairing on, a key.
format_status(Status) ->
    erx_report:status(Status, #{state => keep, message => fun write_size/1}).

write_size({write, From, Bytes}) when is_binary(Bytes) -> {write, From, erx_report:bytes(Bytes)};
write_size(_Message) -> hidden.
