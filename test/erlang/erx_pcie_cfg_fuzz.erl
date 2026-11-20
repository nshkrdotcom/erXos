%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_pcie_cfg (docs/design-pcie.md, "Fuzz targets"): parse/1 over
%% the cases' snapshots and their mutations, generated capability lists and random
%% bytes, and size/2 over sizing answers and their mutations. Neither may crash or answer
%% outside its contract; a parsed read value must keep every capability's fields inside
%% the snapshot, each BAR in its place and the MSI-X table inside a memory BAR's 4 GiB.
%% A crash prints `crash`, a value past a bound `out_of_bounds`, and either halts
%% nonzero; tools/fuzz/erx_pcie_cfg.rb runs it.
-module(erx_pcie_cfg_fuzz).

-export([run/1]).

-define(ROUNDS, 40000).
-define(SNAPSHOT, 256).
-define(PARSE_REASONS, [snapshot, header_type, pin, capability_pointer, capability_list,
                        msi, msix, express, msix_table_bar, msix_table_offset]).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Accepted = lists:foldl(fun(_, N) -> N + parse_round(snapshot()) end, 0, lists:seq(1, ?ROUNDS)),
    Sized = lists:foldl(fun(_, N) -> N + size_round(answer()) end, 0, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~b rounds ok, ~b accepted, ~b sized~n", [2 * ?ROUNDS, Accepted, Sized]).

parse_round(Bytes) ->
    identity_sound(Bytes),
    Answer = try erx_pcie_cfg:parse(Bytes)
             catch Class:Reason:Stack -> fail(crash, Bytes, {Class, Reason, Stack})
             end,
    case Answer of
        {ok, Read} ->
            sound(Read) orelse fail(out_of_bounds, Bytes, Read),
            1;
        {error, {duplicate, Name}} when Name =:= msi; Name =:= msix; Name =:= express ->
            0;
        {error, {bar, Index}} when Index =:= 1; Index =:= 5 ->
            0;
        {error, Why} ->
            lists:member(Why, ?PARSE_REASONS) orelse fail(crash, Bytes, {error, Why}),
            0;
        Other ->
            fail(crash, Bytes, Other)
    end.

%% identity/1 takes every 256-byte snapshot, whatever its header type, and
%% refuses any other length.
identity_sound(Bytes) ->
    Answer = try erx_pcie_cfg:identity(Bytes)
             catch Class:Reason:Stack -> fail(crash, Bytes, {Class, Reason, Stack})
             end,
    case {byte_size(Bytes), Answer} of
        {?SNAPSHOT, {ok, #{header_type := Type}}} when Type =< 16#7f -> ok;
        {Size, {error, snapshot}} when Size =/= ?SNAPSHOT -> ok;
        _ -> fail(crash, Bytes, Answer)
    end.

%% What a read value promises, restated from the design rather than from the module.
sound(#{bars := Bars, msi := Msi, msix := Msix, express := Express, pin := Pin,
        header := Header}) ->
    length(Bars) =:= 6
        andalso [I || #{index := I} <- Bars] =:= lists:seq(0, 5)
        andalso wide_bars_sound(Bars)
        andalso Pin =< 4
        andalso (Header =/= bridge orelse lists:all(fun(#{kind := K}) -> K =:= absent end,
                                                    lists:nthtail(2, Bars)))
        andalso inside(Msi, msi_extent(Msi))
        andalso inside(Msix, 16#0c)
        andalso inside(Express, 16#0c)
        andalso table_sound(Msix, Bars).

wide_bars_sound([#{kind := memory, addr64 := true}, #{kind := absent} | Rest]) ->
    wide_bars_sound(Rest);
wide_bars_sound([#{addr64 := true} | _]) ->
    false;
wide_bars_sound([_ | Rest]) ->
    wide_bars_sound(Rest);
wide_bars_sound([]) ->
    true.

%% Each capability's structure through its last register in pcireg.h: MSI's pending
%% bits or data, MSI-X's pending-bit array register, PCI Express's device status.
msi_extent(#{addr64 := true, vector_mask := true}) -> 16#18;
msi_extent(#{addr64 := true}) -> 16#0e;
msi_extent(_) -> 16#0a.

inside(none, _Extent) -> true;
inside(#{offset := At}, Extent) -> At >= 16#40 andalso At band 3 =:= 0 andalso At + Extent =< ?SNAPSHOT.

table_sound(none, _Bars) ->
    true;
table_sound(#{table_bar := Bar, table_offset := Offset, table_size := Entries}, Bars) ->
    Bar =< 5 andalso maps:get(kind, lists:nth(Bar + 1, Bars)) =:= memory
        andalso Entries >= 1 andalso Entries =< 2048
        andalso Offset + 16 * Entries =< 1 bsl 32.

size_round({Bar, Answer}) ->
    Result = try erx_pcie_cfg:size(Bar, Answer)
             catch Class:Reason:Stack -> fail(crash, {Bar, Answer}, {Class, Reason, Stack})
             end,
    case Result of
        {ok, Log2} ->
            size_sound(Bar, Answer, Log2) orelse fail(out_of_bounds, {Bar, Answer}, Result),
            1;
        absent ->
            0;
        {error, {bar_mask, Index}} ->
            Index =:= maps:get(index, Bar) orelse fail(crash, {Bar, Answer}, Result),
            0;
        Other ->
            fail(crash, {Bar, Answer}, Other)
    end.

%% A size answered is the answer's lowest base bit, within the register's width; for
%% a memory BAR it is the whole base mask, every base bit from the size up set. An I/O
%% BAR is spared that contiguity, as FreeBSD spares every BAR.
size_sound(#{kind := Kind, addr64 := Wide}, Answer, Log2) ->
    {Low, Width} = case {Kind, Wide} of
                       {io, false} -> {2, 32};
                       {memory, false} -> {4, 32};
                       {memory, true} -> {4, 64}
                   end,
    Base = Answer band ((1 bsl Width) - (1 bsl Low)),
    Log2 >= Low andalso Log2 < Width
        andalso Base band -Base =:= 1 bsl Log2
        andalso (Kind =:= io orelse Base =:= (1 bsl Width) - (1 bsl Log2)).

fail(Marker, Input, Detail) ->
    io:format("~s: ~p~n input ~p~n", [Marker, Detail, Input]),
    halt(1).

snapshot() ->
    case rand:uniform(10) of
        N when N =< 5 -> mutated(pick([erx_pcie_cfg_tests:endpoint(), erx_pcie_cfg_tests:root_port()]));
        N when N =< 8 -> chain();
        9 -> rand:bytes(?SNAPSHOT);
        10 -> rand:bytes(rand:uniform(300) - 1)
    end.

%% A fixture with a few of its bytes or fields replaced, aimed at the bytes the parser
%% decides on: the header type, the pin, BAR types, pointers and capability words.
mutated(Snapshot) ->
    lists:foldl(fun(_, S) -> mutation(S) end, Snapshot, lists:seq(1, rand:uniform(4))).

mutation(S) ->
    Put = fun erx_pcie_cfg_tests:put/4,
    case rand:uniform(8) of
        1 -> Put(S, rand:uniform(?SNAPSHOT) - 1, 1, rand:uniform(256) - 1);
        2 -> Put(S, 16#0e, 1, pick([0, 1, 2, 16#7f, 16#80, 16#81, 16#82]));
        3 -> Put(S, 16#3d, 1, pick([0, 1, 4, 5, 255]));
        4 -> Put(S, 16#10 + 4 * (rand:uniform(6) - 1), 4,
                 pick([0, 1, 4, 12, 16#fe00000c, 16#ffffffff, rand:uniform(1 bsl 32) - 1]));
        5 -> Put(S, pick([16#34, 16#41, 16#51, 16#71, 16#49]), 1,
                 pick([0, 16#3c, 16#40, 16#41, 16#50, 16#70, 16#fc, 16#ff, rand:uniform(256) - 1]));
        6 -> Offset = pick([rand:uniform(1 bsl 32), (1 bsl 32) - rand:uniform(16#10000)]),
             Put(S, 16#44, 4, (Offset - 1) band 16#fffffff8 bor (rand:uniform(8) - 1));
        7 -> Put(S, pick([16#42, 16#52, 16#72]), 2, pick([0, 16#07ff, 16#8000, 16#0180, 16#01ff, 16#ffff]));
        8 -> Put(S, 16#06, 2, pick([0, 16#0010]))
    end.

%% A blank function with a capability list of random ids, at random places, whose last
%% pointer may close a loop.
chain() ->
    Put = fun erx_pcie_cfg_tests:put/4,
    Places = lists:usort([16#40 + 4 * (rand:uniform(48) - 1) || _ <- lists:seq(1, rand:uniform(8))]),
    Ids = [pick([16#01, 16#05, 16#10, 16#11, rand:uniform(256) - 1]) || _ <- Places],
    Nexts = tl(Places) ++ [pick([0, hd(Places), rand:uniform(256) - 1])],
    Base = Put(Put(erx_pcie_cfg_tests:blank(), 16#06, 2, 16#0010), 16#34, 1, hd(Places)),
    Linked = lists:foldl(fun({At, Id, Next}, S) -> Put(Put(S, At, 1, Id), At + 1, 1, Next) end,
                         Base, lists:zip3(Places, Ids, Nexts)),
    lists:foldl(fun(_, S) -> Put(S, 16#40 + rand:uniform(192) - 1, 1, rand:uniform(256) - 1) end,
                Linked, lists:seq(1, rand:uniform(24))).

answer() ->
    Bar = pick([erx_pcie_cfg_tests:bar(0, memory, false), erx_pcie_cfg_tests:bar(1, io, false),
                erx_pcie_cfg_tests:bar(2, memory, true), erx_pcie_cfg_tests:bar(3, absent, false)]),
    Width = case Bar of #{addr64 := true} -> 64; _ -> 32 end,
    Log2 = rand:uniform(Width) - 1,
    Clean = ((1 bsl Width) - (1 bsl Log2)) bor (rand:uniform(16) - 1),
    Answer = case rand:uniform(4) of
                 1 -> rand:uniform(1 bsl Width) - 1;
                 2 -> Clean bxor (1 bsl (rand:uniform(Width) - 1));
                 _ -> Clean
             end,
    {Bar, Answer band ((1 bsl Width) - 1)}.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
