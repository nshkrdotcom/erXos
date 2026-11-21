%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_places_sup).
-moduledoc """
The USB domain's places (docs/design-usb.md, "Hotplug ends at the
controller's domain", "The process tree"): what a reader outside the USB
domain holds, which lasts as long as the domain does. It supervises one
stream, erx_usb_input_stream, for each input number, `hid0` to `hid7`, and
last the mint of the input tree, erx_usb_input_tree, that serves them, the
files service `usb_input` (erx_fs_mint), whose grants the domain service
hands to the display domain the manifest names. The domain's top
supervisor, erx_usb, starts the places once, from the USB domain's boot
script, before init's ready report, so a domain serves one input tree,
under one service name, and only the USB domain serves it.

The places hold no device state, so nothing beside them, a function's crash
or a controller's reset, ends them. Nothing restarts them either: every
child is permanent and the intensity is 0, so the end of any child ends the
places, and through erx_usb the domain. The domain service
mints a service's grants only for a new incarnation of its domain
(docs/design-system.md, "Facets a configured domain serves"), so places
started again within one incarnation would serve no reader; the domain's
restart is the fresh try.

A function takes its number with occupy_input/2, the lowest number free
when it asks, and holds it until its process ends, when the number's stream
writes `release`. A number is free when it has no occupant and its stream
has room for one read's worth (erx_usb_input_stream).

The mint names itself the service's mint and acknowledges its start before
it mounts the tree; its mount, in the mint's own process, reads the streams
from the places, which by then have started every child and serve the call
(erx_fs_mint). Each grant of the tree holds the streams' pids, which end
only with the places, and so with every grant.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/0, occupy_input/2, streams/1]).
-export([init/1, start_mint/1]).

-doc "Starts the USB domain's places, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

-doc """
Makes Pid the occupant of the lowest input number of Places that is free,
and answers the number and its stream, which takes Pid's records
(erx_usb_input_stream:write/2), or `{error, no_input_number}` when every number is
taken.
""".
-spec occupy_input(pid(), pid()) -> {ok, non_neg_integer(), pid()} | {error, no_input_number}.
occupy_input(Places, Pid) when is_pid(Pid) ->
    lowest(streams(Places), 0, Pid).

-doc "The streams of Places' input numbers, number 0 first, the input tree's arguments in order.".
-spec streams(pid()) -> [pid()].
streams(Places) ->
    [Stream || {_, Stream} <- lists:sort([{N, Stream} || {{input, N}, Stream, _, _} <- supervisor:which_children(Places)])].

%% ---------------------------------------------------------------------------
%% The supervisor's callback
%% ---------------------------------------------------------------------------

-doc false.
init([]) ->
    Streams = [#{id => {input, N}, start => {erx_usb_input_stream, start_link, []}}
               || N <- lists:seq(0, ?ERX_USB_INPUT_MAX - 1)],
    Mint = #{id => mint, start => {?MODULE, start_mint, [self()]}, shutdown => brutal_kill,
             modules => [erx_fs_mint]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, Streams ++ [Mint]}}.

%% The input tree's mint, whose mount answers the streams of Places, number 0 first.
-doc false.
-spec start_mint(pid()) -> {ok, pid()}.
start_mint(Places) ->
    erx_fs_mint:start_link(usb_input, erx_usb_input_tree,
                           fun() -> list_to_tuple(streams(Places)) end).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

lowest([], _N, _Pid) ->
    {error, no_input_number};
lowest([Stream | Rest], N, Pid) ->
    case erx_usb_input_stream:occupy(Stream, Pid) of
        ok -> {ok, N, Stream};
        taken -> lowest(Rest, N + 1, Pid)
    end.
