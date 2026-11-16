%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_sae (tools/fuzz/erx_sae.rb; docs/design-wifi.md, "Untrusted
%% input", fuzz_sae): SAE's Authentication frames from a hostile access point, seeded
%% with the genuine frames of erx_sae_peer's access point, whose arithmetic follows
%% the standard and matches Annex J.10's vectors (a commit, with Rejected Groups lists,
%% one naming group 19 and one of the most groups an element holds, with a password
%% identifier and with both, the station's own commit reflected whole and in part, a
%% confirm, and anti-clogging token requests up to the longest token), then mutated
%% (bytes changed, lengths rewritten, the frame cut or extended, a header or an
%% extension element put in, the scalar or a coordinate set to a bound of its range),
%% and stepped in each state that reads frames:
%% committed, with and without a password identifier, keying and confirmed.
%%
%% Every step returns and never raises, and its outcome satisfies erx_sae's contract:
%% a drop names a check and leaves the exchange unchanged; a commit taken asks for the
%% KCK of exactly the frame's scalar and element, which pass the commit's checks, with
%% its Rejected Groups list as the frame carries it, and leaves the exchange keying,
%% where the same frame is dropped; a token request taken sends the station's own
%% commit again with the frame's token in its container; and an accepted confirm is
%% the access point's own for its send-confirm.
-module(erx_sae_fuzz).
-export([run/1]).

-define(ROUNDS, 200000).
%% Each outcome but a drop is reached at least this often, so a mutation that stops
%% reaching one, or a parser that drops what it should take, fails the run.
-define(MIN_EACH, ?ROUNDS div 1000).
-define(OUTCOMES, [failed, accepted, keyed, keyed_with_list, resent | [{dropped, Check} || Check <- ?CHECKS]]).
-define(SSID, <<"byteme">>).
-define(SPA, <<16#4d, 16#3f, 16#2f, 16#ff, 16#e3, 16#87>>).
-define(AA, <<16#a5, 16#d8, 16#aa, 16#95, 16#8e, 16#3c>>).
-define(IDENTIFIER, <<"psk4internet">>).
-define(COMMIT_FIELDS, 104).
-define(CHECKS, [sae_malformed, sae_unexpected, sae_reflected, bad_element]).

run([Seed]) ->
    rand:seed(exsss, {83, 65, list_to_integer(Seed)}),
    World = world(),
    Tally = lists:foldl(fun(_, Acc) -> maps:update_with(round_of(World), fun(N) -> N + 1 end, Acc) end,
                        maps:from_keys(?OUTCOMES, 0), lists:seq(1, ?ROUNDS)),
    case [Outcome || Outcome := N <- Tally, N < ?MIN_EACH] of
        [] -> io:format("fuzz: ~p rounds ok, ~0p~n", [?ROUNDS, Tally]);
        Rare -> error({too_rarely_reached, Rare, Tally})
    end.

round_of(#{states := States, frames := Frames} = World) ->
    {Name, Sae} = pick(States),
    Frame = mutate(pick(Frames), World),
    Result = guarded(Name, Frame, fun() -> erx_sae:step(Sae, {auth_frame, Frame}, #{now => 0}) end),
    check_outcome(Name, Sae, Frame, Result, World).

check_outcome(_Name, Sae, Frame, {Sae1, [{drop, Check}]}, _World) ->
    check(Sae1 =:= Sae andalso lists:member(Check, ?CHECKS), drop_changed_nothing, Frame),
    {dropped, Check};
%% An end is `secret` once the station has confirmed or for an unknown password
%% identifier in a commit, else `bss`.
check_outcome(Name, _Sae, <<_:2/binary, Transaction:16/little, Status:16/little, _/binary>> = Frame,
              {_, [{stop, {failed, Class}}]}, _World) ->
    Expected = case Name =:= confirmed orelse {Transaction, Status} =:= {1, 123} of true -> secret; false -> bss end,
    check(Class =:= Expected, failure_class, Frame),
    failed;
check_outcome(confirmed, _Sae, Frame, {_, [{stop, accepted}]}, #{ap := Ap}) ->
    <<_:6/binary, Sc:16/little, _/binary>> = Frame,
    check(byte_size(Frame) >= 40 andalso binary:part(Frame, 0, 40) =:= erx_sae_peer:ap_confirm(Ap, Sc),
          accepted_only_the_peers_confirm, Frame),
    accepted;
check_outcome(Name, _Sae, Frame, {Keying, [{keys, {sae_key, Request}}, {deadline, Deadline}]}, World)
  when Name =:= committed; Name =:= identified ->
    check_commit_taken(Name, Frame, Request, World),
    check(Deadline =< 5000 andalso not erx_sae:tested(Keying), keying_runs_untested, Frame),
    check({Keying, [{drop, sae_unexpected}]} =:= erx_sae:step(Keying, {auth_frame, Frame}, #{now => 0}),
          keying_drops_a_commit, Frame),
    case Request of #{rejected := <<>>} -> keyed; _ -> keyed_with_list end;
check_outcome(Name, _Sae, Frame, {_, [{auth_frame, Sent}, {deadline, Deadline}]}, #{own := Own})
  when Name =:= committed; Name =:= identified ->
    Prefix = <<Own/binary, (identifier_element(Name))/binary>>,
    check(binary:longest_common_prefix([Sent, Prefix]) =:= byte_size(Prefix) andalso Deadline =< 5000,
          own_commit_sent_again, Frame),
    Container = binary:part(Sent, byte_size(Prefix), byte_size(Sent) - byte_size(Prefix)),
    check(byte_size(Frame) >= 8 + byte_size(Container)
          andalso binary:part(Frame, 8, byte_size(Container)) =:= Container
          andalso token_container(Container), token_from_the_frame, Frame),
    resent;
check_outcome(Name, _Sae, Frame, Result, _World) ->
    error({outside_contract, Name, Frame, Result}).

%% A commit taken: the frame's fields re-encode from the request, the scalar is from 2
%% to r - 1 and the coordinates below the prime, neither value is the station's own,
%% and the request's list is the frame's, even, non-empty when present and without
%% group 19, after the station's identifier when it has one.
check_commit_taken(Name, Frame, #{ssid := ?SSID, scalar := Scalar, element := Element, rejected := Rejected},
                   #{own := Own, curve := #{p := P, r := R}}) ->
    <<_:8/binary, OwnScalar:32/binary, OwnElement:64/binary>> = Own,
    <<X:256, Y:256>> = Element,
    check(binary:part(Frame, 0, ?COMMIT_FIELDS) =:= <<3, 0, 1, 0, 126, 0, 19, 0, Scalar/binary, Element/binary>>,
          commit_re_encodes, Frame),
    check(binary:decode_unsigned(Scalar) >= 2 andalso binary:decode_unsigned(Scalar) < R andalso X < P andalso Y < P,
          commit_in_range, Frame),
    check(Scalar =/= OwnScalar andalso Element =/= OwnElement, commit_not_reflected, Frame),
    After = binary:part(Frame, ?COMMIT_FIELDS, byte_size(Frame) - ?COMMIT_FIELDS),
    {PeerId, Rest} = case After of
                         <<255, Length, 33, Id:(Length - 1)/binary, Tail/binary>> -> {Id, Tail};
                         _ -> {none, After}
                     end,
    check(Name =:= committed orelse PeerId =:= ?IDENTIFIER, identifier_carried, Frame),
    Listed = case Rest of
                 <<255, ListLength, 92, List:(ListLength - 1)/binary, _/binary>> -> List;
                 _ -> <<>>
             end,
    Groups = [Group || <<Group:16/little>> <= Rejected],
    check(Rejected =:= Listed andalso byte_size(Rejected) rem 2 =:= 0 andalso not lists:member(19, Groups),
          rejected_groups_from_the_frame, Frame).

identifier_element(identified) -> <<255, 13, 33, ?IDENTIFIER/binary>>;
identifier_element(committed) -> <<>>.

token_container(<<255, Length, 93, Token/binary>>) -> byte_size(Token) =:= Length - 1;
token_container(_) -> false.

guarded(Name, Frame, Fun) ->
    try
        Fun()
    catch
        Class:Reason:Stack -> error({crash, Name, Frame, Class, Reason, Stack})
    end.

check(true, _Property, _Input) -> ok;
check(false, Property, Input) -> error({Property, Input}).

%% ---- The exchange's parties and their genuine frames ----

%% The station committed with and without a password identifier, keying on the access
%% point's commit and confirmed, from the fake holder; the access point that took the
%% station's commit; and the frames it and another access point send.
world() ->
    {S, H, Commit} = committed(#{}),
    %% The same draws make the same scalar and element, so both stations' commits
    %% share their fields and differ in the identifier's container.
    {Si, _, CommitI} = committed(#{identifier => ?IDENTIFIER}),
    true = binary:part(CommitI, 0, ?COMMIT_FIELDS) =:= binary:part(Commit, 0, ?COMMIT_FIELDS),
    Ap0 = ap(#{}, <<41:256>>),
    {[ApCommit], Ap} = erx_sae_peer:ap_take(Commit, Ap0),
    {K, [{keys, Ask}, {deadline, _}]} = erx_sae:step(S, {auth_frame, ApCommit}, #{now => 0}),
    {Answer, _} = erx_sae_peer:holder(Ask, H),
    {C, [{auth_frame, _Confirm}, {deadline, _}]} = erx_sae:step(K, {key, Answer}, #{now => 0}),
    Listed = erx_sae_peer:ap_commit(ap(#{rejected => <<20:16/little, 21:16/little>>}, <<43:256>>)),
    Downgrade = erx_sae_peer:ap_commit(ap(#{rejected => <<20:16/little, 19:16/little>>}, <<47:256>>)),
    Longest = erx_sae_peer:ap_commit(ap(#{rejected => binary:copy(<<20:16/little>>, 127)}, <<53:256>>)),
    <<Header:8/binary, ApScalar:32/binary, ApElement:64/binary>> = ApCommit,
    <<_:8/binary, OwnScalar:32/binary, OwnElement:64/binary>> = Commit,
    IdElement = <<255, 13, 33, ?IDENTIFIER/binary>>,
    <<_:?COMMIT_FIELDS/binary, ListElement/binary>> = Listed,
    #{states => [{committed, S}, {identified, Si}, {keying, K}, {confirmed, C}],
      frames => [ApCommit, Listed, Downgrade, Longest, <<ApCommit/binary, IdElement/binary>>,
                 <<ApCommit/binary, IdElement/binary, ListElement/binary>>,
                 <<Header/binary, OwnScalar/binary, OwnElement/binary>>,
                 <<Header/binary, OwnScalar/binary, ApElement/binary>>,
                 <<Header/binary, ApScalar/binary, OwnElement/binary>>,
                 erx_sae_peer:ap_confirm(Ap, 1),
                 erx_sae_peer:ap_token_request(Ap#{token := <<"token">>}),
                 erx_sae_peer:ap_token_request(Ap#{token := binary:copy(<<"t">>, 254)})],
      ap => Ap, own => binary:part(Commit, 0, ?COMMIT_FIELDS), curve => erx_sae_peer:curve()}.

committed(Identifier) ->
    Sae = erx_sae:new(Identifier#{ssid => ?SSID, spa => ?SPA, aa => ?AA}),
    {S0, [{keys, Ask}, {deadline, _}]} = erx_sae:step(Sae, start, #{now => 0}),
    {U1, U2} = erx_sae_peer:hashed_values(?SSID, <<"mekmitasdigoat">>, <<>>),
    Holder = erx_sae_peer:holder_new(erx_sae_peer:pt(U1, U2), [{<<N:256>>, <<(N + 7):256>>} || N <- [1, 11]]),
    {Answer, H} = erx_sae_peer:holder(Ask, Holder),
    {S, [{auth_frame, Commit}, {deadline, _}]} = erx_sae:step(S0, {key, Answer}, #{now => 0}),
    {S, H, Commit}.

ap(Config, Rand) ->
    {U1, U2} = erx_sae_peer:hashed_values(?SSID, <<"mekmitasdigoat">>, <<>>),
    erx_sae_peer:ap_new(Config#{pt => erx_sae_peer:pt(U1, U2), aa => ?AA, spa => ?SPA, rand => Rand,
                                mask => <<1000003:256>>}).

%% ---- Mutations ----

%% None, one or several of: a byte changed, a byte made a length-like value, the bytes
%% cut short or extended, the header's transaction or status changed, or an extension
%% element of the commit's put after its fields, or its scalar or a coordinate made a
%% value at a bound of its range.
mutate(Bytes, #{curve := #{p := P, r := R}}) ->
    Bounds = [0, 1, 2, R - 1, R, P - 1, P, (1 bsl 256) - 1],
    lists:foldl(fun(_, Acc) -> mutation(pick([flip, length, cut, extend, header, element, {field, Bounds}]), Acc) end,
                Bytes, lists:seq(1, rand:uniform(4) - 1)).

mutation(_, <<>>) -> <<>>;
mutation(flip, Bytes) -> replace(Bytes, rand:uniform(256) - 1);
mutation(length, Bytes) -> replace(Bytes, pick([0, 1, 2, 3, 4, 5, 13, 14, 32, 33, 92, 93, 127, 128, 254, 255]));
mutation(cut, Bytes) -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
mutation(extend, Bytes) -> <<Bytes/binary, (rand:bytes(rand:uniform(8)))/binary>>;
mutation(header, <<3, 0, _:4/binary, Body/binary>>) ->
    <<3, 0, (pick([1, 2, 3])):16/little, (pick([0, 1, 76, 77, 123, 126, rand:uniform(65536) - 1])):16/little,
      Body/binary>>;
mutation(header, Bytes) -> Bytes;
mutation(element, Bytes) when byte_size(Bytes) >= ?COMMIT_FIELDS ->
    <<Fields:?COMMIT_FIELDS/binary, _/binary>> = Bytes,
    Length = pick([0, 1, 2, 3, 13, 255, rand:uniform(256) - 1]),
    Ext = pick([33, 92, 93, rand:uniform(256) - 1]),
    <<Fields/binary, 255, Length, Ext, (rand:bytes(rand:uniform(40) - 1))/binary>>;
mutation(element, Bytes) -> Bytes;
mutation({field, Bounds}, Bytes) when byte_size(Bytes) >= ?COMMIT_FIELDS ->
    At = pick([8, 40, 72]),
    <<Head:At/binary, _:32/binary, Tail/binary>> = Bytes,
    <<Head/binary, (pick(Bounds)):256, Tail/binary>>;
mutation({field, _}, Bytes) -> Bytes.

replace(Bytes, Value) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Head:At/binary, _, Tail/binary>> = Bytes,
    <<Head/binary, Value, Tail/binary>>.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
