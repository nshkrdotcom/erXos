%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_echo_test).
-moduledoc """
Test only: the serial service's echo (docs/design-bluetooth.md, "On QEMU against
Bumble"). The application's supervisor starts one process, registered under this
module's name, which starts erx_gatt_serial linked to itself and sends each
`{serial, Conn, Bytes}` back with erx_gatt_serial:send/2, so a phone reads on `tx`
every byte it wrote to `rx`, in order. A failed send ends the echo, and the supervisor
starts it and its handler again.
""".

-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1, start_link/0, echo_init/1]).

-doc false.
start(_Type, _Args) ->
    supervisor:start_link({local, erx_gatt_echo_test_sup}, ?MODULE, []).

-doc false.
stop(_State) ->
    ok.

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => echo, start => {?MODULE, start_link, []}}]}}.

-doc "Starts the echo and its serial handler, linked to the caller.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    proc_lib:start_link(?MODULE, echo_init, [self()]).

-doc false.
echo_init(Parent) ->
    register(?MODULE, self()),
    case erx_gatt_serial:start_link(self()) of
        {ok, _Serial} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            echo();
        {error, Reason} ->
            proc_lib:init_fail(Parent, {error, Reason}, {exit, normal})
    end.

echo() ->
    receive
        {serial, Conn, Bytes} ->
            ok = erx_gatt_serial:send(Conn, Bytes),
            echo();
        _Other ->
            echo()
    end.
