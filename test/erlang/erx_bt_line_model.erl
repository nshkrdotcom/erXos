%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A model of the line's two files and the controller behind them, for
%% erx_bt_group_tests (docs/design-bluetooth.md, "Verification", the controller group's
%% row). open/2 is the group's Open: each open makes an I/O device, a process speaking
%% OTP's I/O protocol (what file:read/2 and file:write/2 send to a pid), which forwards
%% each request, named by its file, to the model. The model keeps the line service's
%% contract:
%%   * `ctl`: `reset` answers after the configured delay, or `{error, eio}` at once when the
%%     model is made with `ctl => eio`; the receive buffer is emptied before the answer;
%%   * `data`: a read waits while nothing is buffered and answers everything buffered; a
%%     read waiting at a reset, or made during one, answers `{error, eio}`.
%% The controller behind `data` answers every command well (Command Complete with the
%% return parameters a sound controller gives; Disconnect with Command Status and then
%% Disconnection Complete), and the test adds bytes from it with inject/2. Every reset,
%% read and write is kept in order in a log the test reads with log/1.
-module(erx_bt_line_model).

-export([start/1, open/1, inject/2, log/1, stop/1]).

-record(model, {
    delay :: non_neg_integer() | eio,          % ctl's answer: after Delay ms, or eio
    credits :: pos_integer(),                  % LE Read Buffer Size's count
    rx = <<>> :: binary(),
    read = none :: none | {pid(), term()},     % the read waiting
    resetting = false :: boolean(),
    log = [] :: [term()]                       % newest first
}).

%% A model with options `ctl` (milliseconds or `eio`, default 20) and `credits` (default 2).
start(Options) ->
    Model = #model{delay = maps:get(ctl, Options, 20), credits = maps:get(credits, Options, 2)},
    spawn(fun() -> loop(Model) end).

%% The group's Open over the model: the file's I/O device, linked to the opener.
open(Model) ->
    fun(<<"/line/", File/binary>>, _Modes) when File =:= <<"data">>; File =:= <<"ctl">> ->
            Name = binary_to_atom(File),
            {ok, spawn_link(fun() -> device(Model, Name) end)}
    end.

inject(Model, Bytes) -> Model ! {inject, Bytes}, ok.

log(Model) ->
    Ref = make_ref(),
    Model ! {log, self(), Ref},
    receive {Ref, Log} -> Log after 2000 -> error(model_timeout) end.

stop(Model) -> exit(Model, kill).

device(Model, File) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            Model ! {File, From, ReplyAs, Request},
            device(Model, File)
    end.

loop(Model) ->
    receive
        {data, From, ReplyAs, {get_chars, _Encoding, _Prompt, _N}} ->
            loop(read(From, ReplyAs, Model));
        {data, From, ReplyAs, {put_chars, _Encoding, Bytes}} ->
            reply(From, ReplyAs, ok),
            loop(answer(Bytes, logged({write, Bytes}, Model)));
        {ctl, From, ReplyAs, {put_chars, _Encoding, <<"reset">>}} ->
            loop(reset(From, ReplyAs, Model));
        {reset_done, From, ReplyAs} ->
            reply(From, ReplyAs, ok),
            loop(logged(reset_done, Model#model{resetting = false, rx = <<>>}));
        {inject, Bytes} ->
            loop(deliver(Model#model{rx = <<(Model#model.rx)/binary, Bytes/binary>>}));
        {log, Asker, Ref} ->
            Asker ! {Ref, lists:reverse(Model#model.log)},
            loop(Model)
    end.

read(From, ReplyAs, #model{resetting = true} = Model) ->
    reply(From, ReplyAs, {error, eio}),
    logged(read_at_reset, Model);
read(From, ReplyAs, Model) ->
    deliver(logged(read, Model#model{read = {From, ReplyAs}})).

reset(From, ReplyAs, #model{delay = eio} = Model) ->
    reply(From, ReplyAs, {error, eio}),
    Model;
reset(From, ReplyAs, #model{delay = Delay, read = Read} = Model) ->
    case Read of
        {Reader, ReaderAs} -> reply(Reader, ReaderAs, {error, eio});
        none -> ok
    end,
    erlang:send_after(Delay, self(), {reset_done, From, ReplyAs}),
    logged(reset, Model#model{resetting = true, read = none}).

deliver(#model{read = {From, ReplyAs}, rx = Rx} = Model) when Rx =/= <<>> ->
    reply(From, ReplyAs, Rx),
    Model#model{read = none, rx = <<>>};
deliver(Model) ->
    Model.

reply(To, ReplyAs, Reply) -> To ! {io_reply, ReplyAs, Reply}.

logged(Event, #model{log = Log} = Model) -> Model#model{log = [Event | Log]}.

%% The controller: a command's answers go to the receive buffer; an ACL packet is taken.
answer(<<1, 16#0406:16/little, 3, Handle:16/little, _Reason>>, Model) ->
    deliver(Model#model{rx = <<(Model#model.rx)/binary, 4, 16#0F, 4, 0, 1, 16#0406:16/little,
                               4, 16#05, 4, 0, Handle:16/little, 16#16>>});
answer(<<1, Opcode:16/little, _Length, _Parameters/binary>>, #model{credits = Credits} = Model) ->
    Return = good(Opcode, Credits),
    deliver(Model#model{rx = <<(Model#model.rx)/binary, 4, 16#0E, (3 + byte_size(Return)), 1,
                               Opcode:16/little, Return/binary>>});
answer(<<2, _/binary>>, Model) ->
    Model.

good(16#1001, _) -> <<0, 9, 0, 0, 9, 15:16/little, 0, 0>>;
good(16#1002, _) -> <<0, 0:512>>;
good(16#2003, _) -> <<0, 0:64>>;
good(16#1009, _) -> <<0, 1, 2, 3, 4, 5, 6>>;
good(16#2002, Credits) -> <<0, 251:16/little, Credits>>;
good(_, _) -> <<0>>.
