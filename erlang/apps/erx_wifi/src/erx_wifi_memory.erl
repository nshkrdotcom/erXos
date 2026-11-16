%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wifi_memory).

-moduledoc """
The station's failure memory (docs/design-wifi.md, "Failure memory"): which BSS and
which network's secret failed lately, and until when each is held. It is a pure
value: every function takes the time it compares with, in milliseconds of the
station's monotonic clock, and the memory keeps no timer, so a hold simply ends
when a later choice compares it with a later time.

Two kinds of record, one rule each:

* `{bss, BSSID}`, counted by every join of the BSS that ended `bss` or `secret`:
  held from the first failure, 10 s doubling to 300 s, and forgotten an hour after
  its hold ended. At most 32 are kept; of the others, the one whose hold ends first goes.
* `{secret, SSID}`, counted by every join of the SSID that ended `secret`: held
  from the third consecutive one, 300 s doubling to an hour. A record exists only
  for an SSID that has a secret, since only such a join ends `secret`, and the
  `ctl` command `names` forgets every one.

A port that stayed open forgets both of its join's records (ok/2). The memory
reads nothing of a network's security, and the choice's admission reads nothing of
the memory, so no failure moves a join to a weaker AKM.
""".

-export([new/0, fail/3, ok/2, held/3, forget_secrets/1]).
-export_type([memory/0, class/0]).

-define(BSS_FIRST, 10_000).
-define(BSS_CAP, 300_000).
-define(BSS_FORGET, 3_600_000).
-define(BSS_RECORDS, 32).
-define(SECRET_FROM, 3).
-define(SECRET_FIRST, 300_000).
-define(SECRET_CAP, 3_600_000).
%% Beyond this many doublings every hold is at its cap; the bound keeps the
%% arithmetic small however long a BSS keeps failing.
-define(DOUBLINGS_MAX, 16).

-type bssid() :: <<_:48>>.
-type ssid() :: binary().
%% How a join ended, as erx_wifi_join classes it: all the memory reads.
-type class() :: secret | bss | none.
-type hold() :: #{count := pos_integer(), until := integer()}.
-opaque memory() :: #{{bss, bssid()} | {secret, ssid()} => hold()}.

-doc "The empty memory, as at the station's start, `reconfigure` and `ssid`.".
-spec new() -> memory().
new() -> #{}.

-doc """
Counts a join of BSSID, a BSS of SSID, that ended at Now in Class. A `none` end
counts nothing.
""".
-spec fail(memory(), {class(), bssid(), ssid()}, integer()) -> memory().
fail(Memory, {none, _, _}, _Now) ->
    Memory;
fail(Memory, {bss, Bssid, _}, Now) ->
    count_bss(Memory, Bssid, Now);
fail(Memory, {secret, Bssid, Ssid}, Now) ->
    count_secret(count_bss(Memory, Bssid, Now), Ssid, Now).

-doc "Forgets the records of a join whose port stayed open `wifi_short_link`.".
-spec ok(memory(), {bssid(), ssid()}) -> memory().
ok(Memory, {Bssid, Ssid}) ->
    maps:without([{bss, Bssid}, {secret, Ssid}], Memory).

-doc """
Whether BSSID, a BSS of SSID, is held at Now, and until when. A held secret is
named first, since of the two it is the one a person can act on; the time is the
later end of the two holds, when the BSS may be tried again.
""".
-spec held(memory(), {bssid(), ssid()}, integer()) -> none | {bss | secret_failed, integer()}.
held(Memory, {Bssid, Ssid}, Now) ->
    case {until(Memory, {secret, Ssid}, Now), until(Memory, {bss, Bssid}, Now)} of
        {none, none} -> none;
        {none, Bss} -> {bss, Bss};
        {Secret, none} -> {secret_failed, Secret};
        {Secret, Bss} -> {secret_failed, max(Secret, Bss)}
    end.

-doc """
Forgets every secret's record, as the `ctl` command `names` does once an
administrator has changed a secret. The key holder's answer to the station's own
`names` request before each choice forgets nothing: called there, it would lift
the secret hold before every attempt.
""".
-spec forget_secrets(memory()) -> memory().
forget_secrets(Memory) ->
    maps:filter(fun(Key, _) -> not is_secret(Key) end, Memory).

is_secret({secret, _Ssid}) -> true;
is_secret({bss, _Bssid}) -> false.

%% The end of Key's hold when it is later than Now, else none.
until(Memory, Key, Now) ->
    case Memory of
        #{Key := #{until := Until}} when Until > Now -> Until;
        #{} -> none
    end.

count_bss(Memory, Bssid, Now) ->
    Key = {bss, Bssid},
    Live = maps:filter(fun(Other, #{until := Until}) -> is_secret(Other) orelse Until + ?BSS_FORGET > Now end,
                       Memory),
    Count = count(Live, Key) + 1,
    Bounded = bounded(Live, Key),
    Bounded#{Key => #{count => Count, until => Now + hold(?BSS_FIRST, ?BSS_CAP, Count - 1)}}.

count_secret(Memory, Ssid, Now) ->
    Count = count(Memory, {secret, Ssid}) + 1,
    Until = case Count >= ?SECRET_FROM of
                true -> Now + hold(?SECRET_FIRST, ?SECRET_CAP, Count - ?SECRET_FROM);
                false -> Now
            end,
    Memory#{{secret, Ssid} => #{count => Count, until => Until}}.

count(Memory, Key) ->
    case Memory of
        #{Key := #{count := Count}} -> Count;
        #{} -> 0
    end.

%% Memory with room for Key: while Key would make more than ?BSS_RECORDS BSS
%% records, the other record whose hold ends first is dropped. Key itself is never
%% the one dropped, so the failure just counted always holds its BSS.
bounded(Memory, Key) ->
    Others = [{Until, Other} || {{bss, _} = Other, #{until := Until}} <- maps:to_list(Memory), Other =/= Key],
    case length(Others) >= ?BSS_RECORDS of
        true ->
            {_, First} = lists:min(Others),
            bounded(maps:remove(First, Memory), Key);
        false ->
            Memory
    end.

%% First doubled Doublings times, never past Cap.
hold(First, Cap, Doublings) ->
    min(Cap, First bsl min(Doublings, ?DOUBLINGS_MAX)).
