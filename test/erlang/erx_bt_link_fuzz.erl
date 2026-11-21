%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the link's ACL input (docs/design-bluetooth.md, "Fuzz targets"):
%% erx_bt_link_core:step/3 over the ACL packets a radio peer sends, cut from frames on
%% every fixed channel and on others (Core 6.3 Vol 3 Part A, 3.1), with random boundary
%% flags, lengths and bytes, interleaved with what the link's other parties send: the
%% controller's encryption reports and completions, the window's verdicts, handlers'
%% answers, notifications and the store's answer, at random times. Whatever arrives, the
%% core neither makes an atom nor raises, and:
%%
%% * the packets outstanding never pass the link's share, and the queue never holds more
%%   than bt_notify_queue frames and the two ATT may add;
%% * no packet handed over passes the controller's length;
%% * the link is encrypted only with a key.
%%
%% A step that ends the link starts a new one. The seed comes from make check-fuzz.

-module(erx_bt_link_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(SHARE, 3).
-define(QUEUE, 16).                       % bt_notify_queue
-define(KEYS, [{svc, open_w}, {svc, enc_n}, {svc, ind}, {gap, device_name}]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loaded before the atoms are counted, since loading a module makes its atoms.
    [{module, _} = code:ensure_loaded(M) || M <- [erx_bt_link_core, erx_l2cap, erx_att, erx_gatt_db, erx_gatt_gate,
                                                  erx_gatt_server, erx_smp, erx_smp_core, erx_smp_crypto, erx_bytes,
                                                  crypto, queue, lists, binary, maps]],
    Table = erx_gatt_db:build(services()),
    _ = erx_bt_link_core:facts(element(1, core(Table))),
    Atoms = erlang:system_info(atom_count),
    _ = lists:foldl(fun(_, {Link, Now}) -> round(Link, Now, Table) end, {core(Table), 0}, lists:seq(1, ?ROUNDS)),
    Atoms =:= erlang:system_info(atom_count) orelse verdict({atoms_made, erlang:system_info(atom_count) - Atoms}),
    io:format("fuzz: ~b rounds ok, seed ~s~n", [?ROUNDS, Seed]).

services() ->
    [#{name => svc, uuid => <<16#00, 16#FF>>,
       characteristics => [#{name => open_w, uuid => <<16#01, 16#FF>>, max => 20,
                             access => #{write => open, write_without_response => open}},
                           #{name => enc_n, uuid => <<16#03, 16#FF>>, max => 20, access => #{notify => encrypted}},
                           #{name => ind, uuid => <<16#04, 16#FF>>, max => 20, access => #{indicate => open}}]}].

%% A new link and the controller's length it was given.
core(Table) ->
    AclTxMax = 26 + rand:uniform(226),
    Bond = case rand:uniform(2) of 1 -> none; 2 -> #{ltk => rand:bytes(16), level => unauthenticated} end,
    {erx_bt_link_core:new(#{table => Table, values => #{}, pairing => rand:uniform(2) =:= 1, bond => Bond,
                           addresses => #{central => {random, <<1:48>>}, peripheral => {public, <<2:48>>}},
                           share => ?SHARE, acl_tx_max => AclTxMax}), AclTxMax}.

round({Core, _} = Link, Now, Table) ->
    At = Now + rand:uniform(3000) - 1,
    Input = case rand:uniform(16) of
                N when N =< 10 -> {acl, boundary(), packet()};
                11 -> lists:nth(rand:uniform(4), [{le_long_term_key_request, 1, <<0:64>>, 0},
                                                 {le_long_term_key_request, 1, rand:bytes(8), rand:uniform(65536) - 1},
                                                 {encryption_change, status(), 1, rand:uniform(4) - 1},
                                                 {encryption_key_refresh_complete, status(), 1}]);
                12 -> lists:nth(rand:uniform(3), [{admission, rand:uniform(3), closed}, {admission, rand:uniform(3), waiting},
                                                 {withdraw, rand:uniform(3)}]);
                13 -> {answer, rand:uniform(4), lists:nth(rand:uniform(3), [ok, {error, 16#80}, junk])};
                14 -> {notify, caller, lists:nth(rand:uniform(2), [notify, indicate]),
                       lists:nth(rand:uniform(length(?KEYS)), ?KEYS), rand:bytes(rand:uniform(30) - 1)};
                15 -> lists:nth(rand:uniform(4), [{kept, ok}, {kept, {error, unavailable}}, busy, completed]);
                16 -> expired
            end,
    step(completed(Input, Core), At, Link, Table).

%% The controller returns at most the packets it was handed.
completed(completed, Core) ->
    case erx_bt_link_core:facts(Core) of
        #{outstanding := 0} -> expired;
        #{outstanding := Outstanding} -> {completed, rand:uniform(Outstanding)}
    end;
completed(Input, _Core) ->
    Input.

step(Input, Now, {Core, AclTxMax}, Table) ->
    {Actions, Next} = try erx_bt_link_core:step(Input, Now, Core)
                      catch Class:Reason -> verdict({core_raised, Input, Class, Reason})
                      end,
    #{outstanding := Outstanding, queued := Queued, encrypted := Encrypted, key := Key} = erx_bt_link_core:facts(Next),
    Outstanding =< ?SHARE orelse verdict({over_share, Input, Outstanding}),
    Queued =< ?QUEUE + 2 orelse verdict({over_queue, Input, Queued}),
    [verdict({encrypted_without_key, Input}) || Encrypted, Key =:= none],
    [verdict({packet_too_long, Input, byte_size(Data)}) || {acl, _, Data} <- Actions, byte_size(Data) > AclTxMax],
    case [R || {close, R} <- Actions] of
        [] -> {{Next, AclTxMax}, Now};
        _ -> {core(Table), Now}
    end.

boundary() ->
    case rand:uniform(16) of
        1 -> rand:uniform(4) - 1;
        _ -> 2
    end.

status() -> case rand:uniform(3) of 1 -> rand:uniform(256) - 1; _ -> 0 end.

%% An ACL packet's data: a whole frame, a frame cut or lengthened, a frame's header with a
%% random length, a piece of one, or random bytes.
packet() ->
    Frame = frame(),
    case rand:uniform(6) of
        1 -> Frame;
        2 -> Frame;
        3 -> binary:part(Frame, 0, rand:uniform(byte_size(Frame)) - 1);
        4 -> <<Frame/binary, (rand:bytes(rand:uniform(8)))/binary>>;
        5 -> <<(rand:uniform(300)):16/little, (cid()):16/little, (rand:bytes(rand:uniform(40) - 1))/binary>>;
        6 -> rand:bytes(rand:uniform(60) - 1)
    end.

frame() ->
    Cid = cid(),
    Payload = payload(Cid),
    <<(byte_size(Payload)):16/little, Cid:16/little, Payload/binary>>.

cid() -> lists:nth(rand:uniform(6), [4, 4, 5, 6, 6, rand:uniform(65536) - 1]).

%% A payload for its channel: an ATT request or command on the attribute table's handles,
%% an SMP command of a random code, a signaling command, or random bytes.
payload(4) ->
    Handle = rand:uniform(14),
    lists:nth(rand:uniform(6), [<<16#12, Handle:16/little, (rand:bytes(rand:uniform(24) - 1))/binary>>,
                                <<16#52, Handle:16/little, (rand:bytes(rand:uniform(24) - 1))/binary>>,
                                <<16#12, Handle:16/little, (rand:uniform(3) - 1):16/little>>,
                                <<16#0A, Handle:16/little>>, <<16#02, (rand:uniform(300)):16/little>>,
                                <<16#1E>>]);
payload(6) ->
    <<(rand:uniform(16)), (rand:bytes(rand:uniform(66) - 1))/binary>>;
payload(5) ->
    Data = rand:bytes(rand:uniform(30) - 1),
    <<(rand:uniform(32)), (rand:uniform(256) - 1), (byte_size(Data)):16/little, Data/binary>>;
payload(_Cid) ->
    rand:bytes(rand:uniform(40) - 1).

verdict(Term) ->
    io:format("~p~n", [Term]),
    halt(1).
