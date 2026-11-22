%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block transport of one medium on a USB mass-storage unit (docs/design-usb.md, "The
%% block transport"): it answers erx_blk's four calls, read, write, flush and info, with the
%% transport contract's answers and closed error set, by handing each request to the
%% medium's BOT function, erx_usb_bot, which runs it through the BOT engine.
%%
%% The function starts one, linked, for each medium that becomes ready, and stops it when
%% the medium ends; it is reached by pid and never registered. It holds the medium's
%% reference, which every request it hands the function carries, so the engine answers a
%% request of a medium that has ended `{error, {device, gone}}` and sends nothing. It checks
%% each request against the contract's bounds before the function sees it: a count of no
%% sectors, or above max_sectors, or bytes that are not whole sectors is bad_count; sectors
%% past the capacity are out_of_range. Every other answer is the engine's: `{device, Detail}`
%% with Detail a sense's three integers, no_sense, reset, short, gone or deadline, and
%% no_flush for a flush of a medium that cannot flush.
%%
%% One request is with the function at a time. The function's call is not timed out here:
%% the engine answers every request within its queue and issue deadlines, 28 s together,
%% inside erx_blk's own call timeout, and the function's end ends this process by the link.

-module(erx_blk_bot).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([medium/0]).

-include("generated/erx_abi.hrl").

%% One bulk buffer's worth of sectors, 64 (docs/design-usb.md, "The block transport").
-define(MAX_SECTORS, (?ERX_XHCI_BULK_BUFFER_SIZE div ?ERX_SCSI_BLOCK_LENGTH)).

-doc "What the function knows of a ready medium: its unit, reference, capacity in sectors, whether it flushes, and the unit's text.".
-type medium() :: #{function := pid(), lun := erx_usb_bot_core:lun(), ref := erx_usb_bot_core:medium_ref(),
                    capacity := pos_integer(), flush := boolean(), detail := map()}.

-doc "Starts the transport of Medium, linked to the caller, its BOT function.".
-spec start_link(medium()) -> {ok, pid()}.
start_link(Medium) ->
    gen_server:start_link(?MODULE, Medium, []).

-doc false.
init(Medium) ->
    {ok, Medium}.

-doc false.
handle_call({read, Sector, Count}, _From, M = #{lun := Lun}) ->
    {reply, checked(Sector, Count, M, fun() -> request({read, Lun, Sector, Count}, M) end), M};
handle_call({write, Sector, Data}, _From, M = #{lun := Lun}) when is_binary(Data),
                                                                   byte_size(Data) rem ?ERX_SCSI_BLOCK_LENGTH =:= 0 ->
    Count = byte_size(Data) div ?ERX_SCSI_BLOCK_LENGTH,
    {reply, checked(Sector, Count, M, fun() -> request({write, Lun, Sector, Data}, M) end), M};
handle_call({write, _Sector, _Data}, _From, M) ->
    {reply, {error, bad_count}, M};
handle_call(flush, _From, M = #{lun := Lun}) ->
    {reply, request({flush, Lun}, M), M};
handle_call(info, _From, M = #{capacity := Capacity, flush := Flush, detail := Detail}) ->
    {reply, {ok, #{transport => usb_bot, capacity => Capacity, max_sectors => ?MAX_SECTORS, flush => Flush,
                   detail => Detail}}, M}.

-doc false.
handle_cast(_Request, M) ->
    {noreply, M}.

-doc false.
handle_info(_Message, M) ->
    {noreply, M}.

%% A crash report leaves out the unit's INQUIRY text and a request's data.
-doc false.
format_status(Status) ->
    maps:map(fun(state, M) -> M#{detail := redacted};
                (message, _Message) -> redacted;
                (_Key, Value) -> Value
             end, Status).

checked(_Sector, Count, _M, _Send) when not is_integer(Count); Count < 1; Count > ?MAX_SECTORS ->
    {error, bad_count};
checked(Sector, Count, #{capacity := Capacity}, _Send) when not is_integer(Sector); Sector < 0;
                                                             Sector + Count > Capacity ->
    {error, out_of_range};
checked(_Sector, _Count, _M, Send) ->
    Send().

request(Request, #{function := Function, ref := Ref}) ->
    erx_usb_bot:request(Function, Ref, Request).
