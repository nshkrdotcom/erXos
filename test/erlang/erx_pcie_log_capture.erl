%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The messages logged while a case's fun runs, for the cases that check a log
%% line: the BCM2711 driver's, the enumerator's and the USB domain's. This module is
%% the logger handler that sends each message to the case's process; every level is
%% let through and the default handler silenced meanwhile, as the runners silence it.
-module(erx_pcie_log_capture).

-export([logged/1, log/2]).

%% Fun's result, or {exit, Reason}, and every message logged while it ran, oldest first.
logged(Fun) ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}}),
    {ok, #{level := Level}} = logger:get_handler_config(default),
    ok = logger:update_handler_config(default, level, none),
    #{level := Primary} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    Result = try Fun() catch exit:Reason -> {exit, Reason}
             after
                 logger:set_primary_config(level, Primary),
                 logger:remove_handler(?MODULE),
                 logger:update_handler_config(default, level, Level)
             end,
    {Result, drain()}.

%% The handler: each message logged as a format and its arguments, sent formatted; a report
%% (a map the bus logs) is not a message and is let go.
log(#{msg := {Format, Args}}, #{config := #{pid := Pid}}) when is_list(Format) ->
    Pid ! {logged, lists:flatten(io_lib:format(Format, Args))};
log(_Event, _Config) ->
    ok.

drain() ->
    receive {logged, Message} -> [Message | drain()]
    after 0 -> []
    end.
