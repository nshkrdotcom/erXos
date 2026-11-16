%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_store).
-moduledoc """
The Bluetooth domain's store (docs/design-bluetooth.md, "The identity address" and "Bonds
and the store"): the one owner of erXos's identity on the air, a static random address. It
makes the address when it starts, from the kernel's generator, and keeps it in memory; it
sits before the controller group in `erx_bt_sup`, so the controller process, which asks for
it at each of its starts, sets the same address across the group's restarts. The bonds, and
keeping the address with them, come with pairing (stage 4).
""".
-behaviour(gen_server).

-export([start_link/0, address/0, static_address/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-doc "Starts the store, registered as `erx_bt_store`, with a new identity address.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "The identity address, most significant octet first.".
-spec address() -> <<_:48>>.
address() ->
    gen_server:call(?MODULE, address).

-doc """
The static random address of six random octets, most significant first, or `retry` when
they make none (Vol 6 Part B, 1.3.2.1, unverified until that part is read): the top two
bits are set, and the other 46 are neither all zeros nor all ones.
""".
-spec static_address(<<_:48>>) -> {ok, <<_:48>>} | retry.
static_address(<<_:2, Random:46>>) when Random =:= 0; Random =:= 1 bsl 46 - 1 ->
    retry;
static_address(<<_:2, Random:46>>) ->
    {ok, <<2#11:2, Random:46>>}.

init([]) ->
    {ok, make_address()}.

make_address() ->
    case static_address(erx_bytes:entropy(6)) of
        {ok, Address} -> Address;
        retry -> make_address()
    end.

handle_call(address, _From, Address) ->
    {reply, Address, Address}.

handle_cast(_Message, Address) ->
    {noreply, Address}.
