%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_sae).

-moduledoc """
SAE's exchange as the join machine sees it (docs/design-wifi.md, "SAE and
protected management frames"): new/1 makes an exchange for one join, and step/3
takes each of its events and returns the actions to perform, the exchange, and an
outcome the join machine acts on. tested/1 says whether a guess of the secret could
now be tested offline from what the station sent, the `secret` class's condition
("Joining", "How a join ends").

The contract a step keeps, which erx_wifi_join's table checks: `{auth_tx, _}` never
ends the exchange; every other event may. An action is `{auth_frame, Frame}`, a
frame to send, or `{keys, Request}`, a request to the key holder made by
erx_wifi_keys, whose answer the next step receives as `{key, Answer}`.

This module is a stand-in that refuses every exchange: start ends it with the
`bss` class, so an SAE join fails, safely, until the exchange itself is written.
""".

-export([new/1, step/3, tested/1]).
-export_type([sae/0, event/0, outcome/0, action/0]).

-opaque sae() :: #{ssid := binary(), spa := <<_:48>>, aa := <<_:48>>}.
-type event() :: start | {auth_frame, binary()} | {auth_tx, ok | failed} | {key, term()} | deadline.
-type action() :: {auth_frame, binary()} | {keys, erx_wifi_keys:request()}.
%% `{running, Deadline}` keeps the exchange going until the time Deadline, when the
%% join machine gives it `deadline`; `accepted` means each side proved the secret.
-type outcome() :: {running, integer()} | accepted | {failed, secret | bss}.

-doc "The exchange of one join: the SSID, the station's address and the BSS's.".
-spec new(#{ssid := binary(), spa := <<_:48>>, aa := <<_:48>>}) -> sae().
new(#{ssid := Ssid, spa := Spa, aa := Aa}) ->
    #{ssid => Ssid, spa => Spa, aa => Aa}.

-doc "One event of the exchange, at the time in Ctx.".
-spec step(sae(), event(), #{now := integer(), _ => _}) -> {[action()], sae(), outcome()}.
step(Sae, {auth_tx, _}, #{now := Now}) ->
    {[], Sae, {running, Now}};
step(Sae, _Event, _Ctx) ->
    {[], Sae, {failed, bss}}.

-doc "Whether the station sent its confirm and no peer confirm has verified.".
-spec tested(sae()) -> boolean().
tested(_Sae) ->
    false.
