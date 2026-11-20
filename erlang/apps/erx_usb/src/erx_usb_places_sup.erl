%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_places_sup).
-moduledoc """
One controller's places (docs/design-usb.md, "Hotplug ends at the
controller's domain", "The process tree"): what a reader outside the USB
domain holds, which lasts as long as the domain does. It supervises one
stream, erx_usb_input_stream, for each input number, `hid0` to `hid7`, and
the grants of the input tree, erx_usb_input_tree, that serve them; its
grants are handed to the display domain the manifest names.

The places hold no device state, so nothing below them, a function's crash
or a controller's reset, ends them; only a fault of their own does. Their
children restart as one (`one_for_all`): the tree's grants hold the
streams' pids, and a restart that kept a grant past its stream would leave
it naming a process that has ended.

A function takes its number with occupy_input/2, the lowest number free
when it asks, and holds it until its process ends, when the number's stream
writes `release`. A number is free when it has no occupant and its stream
has room for one read's worth (erx_usb_input_stream).

A grant of the tree is started by whoever hands it out, with the arguments
input_tree/1 answers beside the grants' supervisor, so no grant's start
calls back into the places, whose own restart may be waiting for that
start to end.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/0, occupy_input/2, input_tree/1]).
-export([init/1]).

-doc "Starts a controller's places, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

-doc """
Makes Pid the occupant of the lowest input number of Places that is free,
and answers the number, or `{error, no_input_number}` when every number is
taken.
""".
-spec occupy_input(pid(), pid()) -> {ok, non_neg_integer()} | {error, no_input_number}.
occupy_input(Places, Pid) when is_pid(Pid) ->
    lowest(streams(supervisor:which_children(Places)), 0, Pid).

-doc """
The supervisor of the input tree's grants (erx_fs_grants) and the arguments
each grant of it starts from, the streams of Places' input numbers, number 0
first: a grant is `erx_fs_grants:grant(Grants, Args, Limits, Binding)`, or
`erx_fs_grants:own(Grants, Args)` for the domain's own.
""".
-spec input_tree(pid()) -> {pid(), tuple()}.
input_tree(Places) ->
    Children = supervisor:which_children(Places),
    [Grants] = [Grants || {input_tree, Grants, _, _} <- Children],
    {Grants, list_to_tuple(streams(Children))}.

%% ---------------------------------------------------------------------------
%% The supervisor's callback
%% ---------------------------------------------------------------------------

-doc false.
init([]) ->
    Streams = [#{id => {input, N}, start => {erx_usb_input_stream, start_link, []}}
               || N <- lists:seq(0, ?ERX_USB_INPUT_MAX - 1)],
    Tree = #{id => input_tree, start => {erx_fs_grants, start_link, [erx_usb_input_tree]},
             type => supervisor},
    {ok, {#{strategy => one_for_all}, Streams ++ [Tree]}}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

%% The streams among the places' children, number 0 first.
streams(Children) ->
    [Stream || {_, Stream} <- lists:sort([{N, Stream} || {{input, N}, Stream, _, _} <- Children])].

lowest([], _N, _Pid) ->
    {error, no_input_number};
lowest([Stream | Rest], N, Pid) ->
    case erx_usb_input_stream:occupy(Stream, Pid) of
        ok -> {ok, N};
        taken -> lowest(Rest, N + 1, Pid)
    end.
