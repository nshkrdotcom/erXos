%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_line_rx).
-moduledoc """
The controller's reader (docs/design-bluetooth.md, "The controller process's effects"): it
opens the line's `data` at its start and reads only after an acknowledgement,
`{read, From}`, sending what it read to `From` as `{erx_bt_line_rx, Bytes}`. The controller
process gives the first acknowledgement once the line's reset has answered, so no read meets
the reset, and each next one once it has stepped the bytes, so one read is outstanding at
most and what the stack has not consumed waits in the line service. A read that fails ends
the reader, and its group with it. It does not trap exits, so the group's shutdown ends it
while it waits in a read.
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% One read takes everything the line holds: line_rx_max, the line service's receive bound
%% (docs/design-bluetooth.md, "The controller's line"). TODO.md records that
%% abi/services/line.txt is to define it.
-define(READ_MAX, 65536).

-doc "Starts the reader, registered as `erx_bt_line_rx`; `Open` is `file:open/2` or a test's model.".
-spec start_link(erx_bt_host_sup:open()) -> gen_server:start_ret().
start_link(Open) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Open, []).

init(Open) ->
    case Open(<<"/line/data">>, [read, binary]) of
        {ok, Data} -> {ok, Data};
        {error, Reason} -> {stop, {line_open, data, Reason}}
    end.

handle_info({read, From}, Data) ->
    case file:read(Data, ?READ_MAX) of
        {ok, Bytes} ->
            From ! {?MODULE, Bytes},
            {noreply, Data};
        Failed ->
            {stop, {line_read, Failed}, Data}
    end;
handle_info(_Message, Data) ->
    {noreply, Data}.

handle_call(_Request, _From, Data) ->
    {reply, {error, unsupported}, Data}.

handle_cast(_Message, Data) ->
    {noreply, Data}.
