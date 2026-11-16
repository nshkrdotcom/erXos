%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A scripted stand-in for erx_sae, compiled in its place by test/host/erx_wifi_join_test.rb
%% so the join machine's exploration reaches every SAE cell of its table: the peer's
%% frame <<"accept">> accepts the exchange, <<"fail">> fails it, any other frame is a
%% commit the station answers with its confirm, after which a guess could be tested;
%% each deadline sends again, at most twice, then fails. The class of a failure is
%% `secret` once the confirm is sent, else `bss`, as "How a join ends" states.
-module(erx_sae).

-export([new/1, step/3, tested/1]).

-define(RESEND_MS, 1_000).

new(#{ssid := _, spa := _, aa := _}) ->
    #{tested => false, resent => 0}.

step(Sae, start, #{now := Now}) ->
    {[{keys, {sae_commit, fake}}], Sae, {running, Now + ?RESEND_MS}};
step(Sae, {key, _Answer}, #{now := Now}) ->
    {[{auth_frame, <<"commit">>}], Sae, {running, Now + ?RESEND_MS}};
step(Sae, {auth_frame, <<"accept">>}, _Ctx) ->
    {[], Sae, accepted};
step(Sae, {auth_frame, <<"fail">>}, _Ctx) ->
    {[], Sae, {failed, class(Sae)}};
step(Sae, {auth_frame, _Commit}, #{now := Now}) ->
    {[{auth_frame, <<"confirm">>}], Sae#{tested := true}, {running, Now + ?RESEND_MS}};
step(Sae, {auth_tx, _}, #{now := Now}) ->
    {[], Sae, {running, Now + ?RESEND_MS}};
step(#{resent := Resent} = Sae, deadline, #{now := Now}) when Resent < 2 ->
    {[{auth_frame, <<"again">>}], Sae#{resent := Resent + 1}, {running, Now + ?RESEND_MS}};
step(Sae, deadline, _Ctx) ->
    {[], Sae, {failed, class(Sae)}}.

tested(#{tested := Tested}) -> Tested.

class(#{tested := true}) -> secret;
class(#{tested := false}) -> bss.
