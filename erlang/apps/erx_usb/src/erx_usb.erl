%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb).
-moduledoc """
The USB domain's application, erx_usb, and its top supervisor
(docs/design-usb.md, "Who holds a controller", "The process tree"): one
controller's supervisor, erx_usb_sup, for each controller the domain holds.

The domain holds its controllers from its creation, each the `usb`
function record of a unit the manifest places on it, and nothing gives it
another while it lives, so the application reads the records once, at its
start (erx_device_record:find/2, the `xhci` peripheral, the one driver the
stack has), and its children are fixed from then on. A record the reader
refuses fails the start, and so the domain's boot.

Each controller's supervisor bounds its own restarts. One that ends past
them ends this supervisor, whose intensity is 0, and with it the permanent
application and the domain, so the domain service's restart, which gives
the domain its units again, is the recovery (docs/design-usb.md, "Failure
handling").
""".
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1]).
-export([start_link/1]).
-export([init/1]).

-doc """
The application's start: the supervisor over the domain's xHCI controllers,
one erx_xhci on each function record the domain holds.
""".
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case erx_device_record:find(usb, xhci) of
        {ok, Specs} ->
            start_link([{erx_xhci, start_link, [Spec]} || Spec <- Specs]);
        {error, _} = Error -> Error
    end.

-doc "The application's stop: nothing to undo beyond its supervisor.".
-spec stop(term()) -> ok.
stop(_State) ->
    ok.

-doc """
Starts the supervisor, registered under its module's name, with one
erx_usb_sup below it for each of Controllers, each a `{Module, Function,
Args}` start of one controller process, in order.
""".
-spec start_link([{module(), atom(), [term()]}]) -> {ok, pid()}.
start_link(Controllers) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Controllers).

-doc false.
init(Controllers) ->
    Children = [#{id => {controller, N}, start => {erx_usb_sup, start_link, [Controller]},
                  type => supervisor}
                || {N, Controller} <- lists:enumerate(0, Controllers)],
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, Children}}.
