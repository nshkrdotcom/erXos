%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb).
-moduledoc """
The USB domain's application, erx_usb, and its top supervisor, registered
under its module's name (docs/design-usb.md, "Who holds a controller", "The
process tree"), in two steps:

* the boot script starts the application, whose supervisor starts the
  domain's places, erx_usb_places_sup, with the input tree's mint as their
  last child, so that the mint names itself the `usb_input` service's mint
  before init's ready report (erx_fs_mint);
* the domain row's `-eval ok=erx_usb:start_controllers()`, which runs once
  init holds the ready answer's facets, `pci` among them, adds one bus group,
  erx_usb_bus_sup, for each controller the domain holds.

The domain holds its controllers from its creation, each the `usb` function
record of a unit the manifest places on it, and nothing gives it another
while it lives, so start_controllers/0 reads the records once
(erx_device_record:find/2, the `xhci` peripheral, the one driver the stack
has). A record the reader refuses fails the eval, and so the domain's boot.

The places are one per domain, permanent, and the intensity is 0, so their
end, or the mint's, ends this supervisor and with it the permanent
application and the domain; the domain service's restart, which gives the
domain its units again and mints the tree's grants anew, is the recovery
(docs/design-usb.md, "Failure handling"). A bus group restarts within
itself and is `transient` here: one that ends past its own bound ends with
`shutdown`, which is not restarted, so the controller is given up while the
places stay.
""".
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1]).
-export([start_link/0, start_controllers/0, start_controllers/1]).
-export([init/1]).

-doc "The application's start, from the boot script: the supervisor and the places below it.".
-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_Type, _Args) ->
    start_link().

-doc "The application's stop: nothing to undo beyond its supervisor.".
-spec stop(term()) -> ok.
stop(_State) ->
    ok.

-doc "Starts the supervisor, registered under its module's name, with the places below it.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Starts a bus group for each xHCI function record the domain holds, for the
domain row's `-eval`; any other answer than `ok` fails the eval and so the
domain's boot.
""".
-spec start_controllers() -> ok.
start_controllers() ->
    {ok, Specs} = erx_device_record:find(usb, xhci),
    start_controllers([{erx_xhci, start_link, [Spec]} || Spec <- Specs]).

-doc """
Starts a bus group below the supervisor for each of Controllers, each a
`{Module, Function, Args}` start of one controller process, in order, each
given the places.
""".
-spec start_controllers([{module(), atom(), [term()]}]) -> ok.
start_controllers(Controllers) ->
    {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(?MODULE)),
    lists:foreach(fun({N, Controller}) ->
                          {ok, _} = supervisor:start_child(?MODULE, #{id => {controller, N},
                                                                      start => {erx_usb_bus_sup, start_link,
                                                                                [Places, Controller]},
                                                                      restart => transient,
                                                                      type => supervisor})
                  end, lists:enumerate(0, Controllers)).

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1},
          [#{id => places, start => {erx_usb_places_sup, start_link, []}, type => supervisor}]}}.
