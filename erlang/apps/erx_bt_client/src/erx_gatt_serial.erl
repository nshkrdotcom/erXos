%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_serial).
-moduledoc """
The serial service (docs/design-bluetooth.md, "Stage 3: the serial service", "For
apps"): the handler of `nus` (abi/gatt/nus.txt), an erx_gatt_service registered under
this module's name, which turns the service into a byte stream for each phone.

* Each write of `rx` is answered `ok` at once and becomes `{serial, Conn, Bytes}` to the
  owner; the owner also hears `{connected, Conn, Info}` and `{disconnected, Conn}`.
* send/2 cuts its bytes into notifications of `tx` of at most `Mtu - 3` octets each,
  `Mtu` the link's bearer MTU as its last `mtu` event gave it, 23 until one comes, and
  returns once all are queued for the link, in order. A notification refused `busy`, the
  link's queue being full, is asked again every `?BUSY_RETRY_MS` until the queue takes it,
  for at most `bt_handler_timeout_ms`; past that send/2 answers `{error, busy}` and the
  rest of the bytes are not sent. `{error, gone}` answers a link that has ended.

The stream is as reliable as ATT makes it: a phone that writes faster than the owner
reads loses the write commands past `bt_write_queue` (ATT 3.3.2); a phone that needs
every byte uses `write` with response. The handler ends with its owner.
""".

-behaviour(erx_gatt_service).

-include("generated/erx_abi.hrl").

-export([start_link/1, send/2]).
-export([init/1, handle_write/4, handle_event/2, handle_call/3, handle_info/2]).

%% How often a notification the link's full queue refused is asked again.
-define(BUSY_RETRY_MS, 5).

-record(serial, {owner :: pid(), mtus = #{} :: #{reference() => pos_integer()}}).

-doc """
Starts the handler of `nus`, linked to the caller, for `Owner`, which hears the stream.
""".
-spec start_link(pid()) -> gen_server:start_ret().
start_link(Owner) when is_pid(Owner) ->
    erx_gatt_service:start_link({local, ?MODULE}, nus, ?MODULE, Owner).

-doc "Sends `Bytes` to the phone of link `Conn` as notifications of `tx`.".
-spec send(reference(), binary()) -> ok | {error, busy | gone | atom()}.
send(Conn, Bytes) when is_reference(Conn), is_binary(Bytes) ->
    erx_gatt_service:call(?MODULE, {send, Conn, Bytes}).

-doc false.
init(Owner) ->
    erlang:monitor(process, Owner),
    {ok, #{}, #serial{owner = Owner}}.

-doc false.
handle_write(Conn, rx, Bytes, #serial{owner = Owner} = Serial) ->
    Owner ! {serial, Conn, Bytes},
    {ok, Serial}.

-doc false.
handle_event({connected, Conn, Info}, #serial{owner = Owner} = Serial) ->
    Owner ! {connected, Conn, Info},
    {ok, Serial};
handle_event({mtu, Conn, Mtu}, #serial{mtus = Mtus} = Serial) ->
    {ok, Serial#serial{mtus = Mtus#{Conn => Mtu}}};
handle_event({disconnected, Conn}, #serial{owner = Owner, mtus = Mtus} = Serial) ->
    Owner ! {disconnected, Conn},
    {ok, Serial#serial{mtus = maps:remove(Conn, Mtus)}};
handle_event({subscribed, _Conn, _Char, _Kind}, Serial) ->
    {ok, Serial}.

-doc false.
handle_call({send, Conn, Bytes}, _From, #serial{mtus = Mtus} = Serial) ->
    Room = maps:get(Conn, Mtus, ?ERX_ATT_MTU_DEFAULT) - 3,
    Deadline = erlang:monotonic_time(millisecond) + ?ERX_BT_HANDLER_TIMEOUT_MS,
    {reply, notify_all(Conn, Bytes, Room, Deadline), Serial}.

-doc false.
handle_info({'DOWN', _Monitor, process, Owner, _Reason}, #serial{owner = Owner}) ->
    exit(normal);
handle_info(_Info, Serial) ->
    {ok, Serial}.

%% Notifies Bytes in pieces of at most Room octets, each once the link's queue takes it.
notify_all(_Conn, <<>>, _Room, _Deadline) ->
    ok;
notify_all(Conn, Bytes, Room, Deadline) ->
    Size = min(Room, byte_size(Bytes)),
    <<Piece:Size/binary, Rest/binary>> = Bytes,
    case notify(Conn, Piece, Deadline) of
        ok -> notify_all(Conn, Rest, Room, Deadline);
        {error, _} = Refusal -> Refusal
    end.

notify(Conn, Piece, Deadline) ->
    case erx_gatt:notify(Conn, nus, tx, Piece) of
        {error, busy} = Busy ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(?BUSY_RETRY_MS), notify(Conn, Piece, Deadline);
                false -> Busy
            end;
        Answer ->
            Answer
    end.
