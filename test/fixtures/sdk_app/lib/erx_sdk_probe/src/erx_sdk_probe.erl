%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(erx_sdk_probe).
-moduledoc """
An app that keeps to the SDK, for its boundary check
(test/host/sdk_test.rb): it calls public functions of erx_ui, stock
OTP, and a function of its own.
""".

-export([run/1]).

-doc "Opens a UI, shows a label, and closes it.".
-spec run(map()) -> ok | {error, term()}.
run(Options) ->
    case erx_ui:open(Options) of
        {ok, Window} ->
            ok = erx_ui:tree(Window, label()),
            erx_ui:close(Window);
        {error, _Why} = Refused ->
            Refused
    end.

label() -> {label, #{text => lists:flatten(io_lib:format("~b", [1]))}}.
