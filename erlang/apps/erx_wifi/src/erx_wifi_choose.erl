%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wifi_choose).

-moduledoc """
The station's choice (docs/design-wifi.md, "Choosing a network"): a pure function
of one view, which returns a verdict for every BSS of the last scan and at most one
pick. The verdicts are what `/proc` shows, so what a front end reads and what the
station acts on are one value.

A BSS's verdict is decided in three steps, each of which may end it:

1. Its network: an SSID is known when a configuration block names it or the key
   holder's names list a secret for it, the second with the default block; `want`
   narrows the known networks. With the names `unavailable` an SSID no block names
   is `keys_unavailable`, since the station cannot tell a network without a secret
   from one whose secret it cannot reach.
2. admit/4: the protection of management frames and the AKM, from the block, the
   SSID's keys, the BSS's RSN element and RSNXE, and the chip. It reads no memory,
   so no failure changes what is admitted or with which AKM and PMF (WF13).
3. The memory: an admitted BSS that is held is postponed, never re-admitted.

Open is a statement, never an absence (WF16): an open BSS is admitted only under a
block whose `key_mgmt` is `NONE` or under `want` `{open, SSID}`, which stands for
that block whatever the configuration and the names say of the SSID.

The BSS records are the scan's, already parsed: the station's chip process reads
the elements, and this module decides from their values.
""".

-export([choose/1, admit/4, default_block/0]).
-export_type([view/0, block/0, bss/0, verdict/0, candidate/0, akm/0, pmf/0, keys/0]).

-type bssid() :: <<_:48>>.
-type ssid() :: binary().
-type akm() :: psk | psk_sha256 | sae.
-type pmf() :: none | capable | required.
-type cipher() :: ccmp | tkip | {other, non_neg_integer()}.
%% A network block of the configuration, every key filled in: open (`[none]`) or
%% protected (a non-empty list of AKMs), never both; SAE never with `ieee80211w` 0.
-type block() :: #{key_mgmt := [none] | [akm(), ...], ieee80211w := 0..2, priority := integer(),
                   _ => _}.
%% The key holder's entry for an SSID, as its `names` answer carries it.
-type entry() :: #{psk := boolean(), sae := boolean(), mark := none | pending | kept, _ => _}.
%% What admit/4 knows of an SSID's secrets: which the names list, and whether the
%% names or the station's marks make it SAE-only; `unavailable` lists none.
-type keys() :: unavailable | #{psk := boolean(), sae := boolean(), sae_only := boolean()}.
%% The RSN element's values: the AKM suites (one the station does not support is
%% `{other, Type}`), the ciphers, and RSN capabilities' MFPC and MFPR.
-type rsn() :: #{akms := [akm() | {other, non_neg_integer()}], pairwise := [cipher()], group := cipher(),
                 mfpc := boolean(), mfpr := boolean()}.
%% A scanned BSS: `open` without the privacy bit, `legacy` with it and no RSN element
%% (WEP or WPA1), else its RSN element; `h2e` is the RSNXE's hash-to-element bit.
-type bss() :: #{bssid := bssid(), ssid := ssid(), signal := integer(),
                 security := open | legacy | {rsn, rsn()}, h2e := boolean(), _ => _}.
-type chip() :: #{sae_ext := boolean(), mfp := boolean()}.
-type want() :: any | {only, ssid()} | {open, ssid()} | none.
-type view() :: #{blocks := #{ssid() => block()}, names := unavailable | {ok, #{ssid() => entry()}},
                  marks := [ssid()], bsss := [bss()], memory := erx_wifi_memory:memory(), want := want(),
                  chip := chip(), joined := bssid() | none, now := integer()}.
-type reason() :: not_wanted | no_secret | keys_unavailable | sae_only | no_sae_ext | no_h2e | pmf_required
                | pmf_unavailable | akm_unsupported | cipher_unsupported | not_open.
-type verdict() :: joined | {candidate, akm() | none, pmf()} | {held, bss | secret_failed, integer()}
                 | unknown | {refused, reason()}.
-type candidate() :: #{bss := bss(), akm := akm() | none, pmf := pmf()}.

%% The block that `want` `{open, SSID}` states.
-define(OPEN_BLOCK, #{key_mgmt => [none], ieee80211w => 0, priority => 0, scan_ssid => false}).
%% The supported AKMs in the order the station prefers them, wpa_supplicant's
%% (wpa_supplicant.c:2140-2169).
-define(PREFERRED, [sae, psk_sha256, psk]).

-doc """
The block of a network known only by its secret, and every value a block leaves
out: the strongest AKM the secret serves, and management frames protected wherever
the access point can.
""".
-spec default_block() -> block().
default_block() ->
    #{key_mgmt => [psk, psk_sha256, sae], ieee80211w => 1, priority => 0, scan_ssid => false}.

-doc """
Every BSS of the view's table with its verdict, in the table's order, and the pick:
the candidate of the highest priority, then the strongest signal, then the lowest
address; none when there is no candidate.
""".
-spec choose(view()) -> #{verdicts := [{bss(), verdict()}], pick := candidate() | none}.
choose(#{bsss := Bsss} = View) ->
    Assessed = [assess(Bss, View) || Bss <- Bsss],
    #{verdicts => [{Bss, Verdict} || {Bss, Verdict, _} <- Assessed], pick => pick(Assessed)}.

pick(Assessed) ->
    Ranked = lists:sort([{-Priority, -Signal, Bssid, #{bss => Bss, akm => Akm, pmf => Pmf}}
                         || {#{bssid := Bssid, signal := Signal} = Bss, {candidate, Akm, Pmf}, Priority} <- Assessed]),
    case Ranked of
        [{_, _, _, Candidate} | _] -> Candidate;
        [] -> none
    end.

%% A BSS's verdict and its network's priority.
assess(#{bssid := Bssid, ssid := Ssid} = Bss, #{chip := Chip} = View) ->
    case network(Ssid, View) of
        {wanted, #{priority := Priority} = Block, Keys} ->
            case admit(Block, Keys, Bss, Chip) of
                {ok, Akm, Pmf} -> {Bss, postponed({Akm, Pmf}, Bssid, Ssid, View), Priority};
                {refused, Reason} -> {Bss, {refused, Reason}, Priority}
            end;
        {verdict, Verdict} ->
            {Bss, Verdict, 0}
    end.

%% An admitted BSS's verdict: the open port's BSS is `joined`, whatever the memory
%% says of it; any other is held while the memory holds it.
postponed(_Admission, Bssid, _Ssid, #{joined := Bssid}) ->
    joined;
postponed({Akm, Pmf}, Bssid, Ssid, #{memory := Memory, now := Now}) ->
    case erx_wifi_memory:held(Memory, {Bssid, Ssid}, Now) of
        none -> {candidate, Akm, Pmf};
        {Kind, Until} -> {held, Kind, Until}
    end.

%% The network of an SSID: wanted with its block and keys, or the verdict that ends
%% the BSS before admission.
network(Ssid, #{want := {open, Ssid}, names := Names, marks := Marks}) ->
    {wanted, ?OPEN_BLOCK, keys(Ssid, Names, Marks)};
network(Ssid, #{blocks := Blocks, names := Names, marks := Marks, want := Want}) ->
    case {block(Ssid, Blocks, Names), Names} of
        {none, unavailable} -> {verdict, {refused, keys_unavailable}};
        {none, {ok, _}} -> {verdict, unknown};
        {Block, _} ->
            case wanted(Want, Ssid) of
                true -> {wanted, Block, keys(Ssid, Names, Marks)};
                false -> {verdict, {refused, not_wanted}}
            end
    end.

block(Ssid, Blocks, Names) ->
    case {Blocks, Names} of
        {#{Ssid := Block}, _} -> Block;
        {#{}, {ok, #{Ssid := #{psk := Psk, sae := Sae}}}} when Psk; Sae -> default_block();
        {#{}, _} -> none
    end.

wanted(any, _Ssid) -> true;
wanted({only, Ssid}, Ssid) -> true;
wanted(_Want, _Ssid) -> false.

keys(_Ssid, unavailable, _Marks) ->
    unavailable;
keys(Ssid, {ok, Entries}, Marks) ->
    Marked = lists:member(Ssid, Marks),
    case Entries of
        #{Ssid := #{psk := Psk, sae := Sae, mark := Mark}} ->
            #{psk => Psk, sae => Sae, sae_only => Marked orelse Mark =/= none};
        #{} ->
            #{psk => false, sae => false, sae_only => Marked}
    end.

-doc """
Whether a BSS may be joined under Block, and with which AKM and PMF; `none` and
`none` for an open network. An open block takes an open BSS alone and every other
block a protected BSS alone. A protected BSS is refused, in this order, when the
names are unavailable, by the design's PMF table, and when it does not offer
CCMP-128 as its pairwise and group cipher. Then the AKM: the station takes SAE,
then PSK-SHA256, then PSK, of those that pass every rule below; when none passes,
the refusal is that of the rule that removed the last one. The rules run in this
order, so `no_secret`, for which a front end offers a passphrase, is reported
only where a secret would make the BSS joinable:

1. `akm_unsupported`: the block allows the AKM and the BSS offers it;
2. `sae_only`: not PSK or PSK-SHA256 for an SSID that is SAE-only;
3. `no_sae_ext`, `no_h2e`: SAE only with `sae_ext` and hash-to-element;
4. `pmf_required` or, where the firmware does not answer `mfp`,
   `pmf_unavailable`: SAE only with PMF;
5. `no_secret`: the AKM's own secret is listed.
""".
-spec admit(block(), keys(), bss(), chip()) -> {ok, akm() | none, pmf()} | {refused, reason()}.
admit(Block, Keys, Bss, Chip) ->
    try
        admitted(Block, Keys, Bss, Chip)
    catch
        throw:{refused, Reason} -> {refused, Reason}
    end.

admitted(#{key_mgmt := [none]}, _Keys, #{security := open}, _Chip) ->
    {ok, none, none};
admitted(#{key_mgmt := [none]}, _Keys, _Bss, _Chip) ->
    refuse(akm_unsupported);
admitted(_Block, _Keys, #{security := open}, _Chip) ->
    refuse(not_open);
admitted(_Block, unavailable, _Bss, _Chip) ->
    refuse(keys_unavailable);
admitted(_Block, _Keys, #{security := legacy}, _Chip) ->
    refuse(akm_unsupported);
admitted(#{key_mgmt := Allowed, ieee80211w := W}, Keys, #{security := {rsn, Rsn}, h2e := H2e}, Chip) ->
    Pmf = pmf(W, Rsn, Chip),
    #{akms := Offered, pairwise := Pairwise, group := Group} = Rsn,
    case lists:member(ccmp, Pairwise) andalso Group =:= ccmp of
        true -> ok;
        false -> refuse(cipher_unsupported)
    end,
    #{sae_only := SaeOnly} = Keys,
    #{sae_ext := SaeExt, mfp := Mfp} = Chip,
    NoPmf = case Mfp of
                true -> pmf_required;
                false -> pmf_unavailable
            end,
    Rules = [{akm_unsupported, fun(Akm) -> lists:member(Akm, Offered) end},
             {sae_only, fun(Akm) -> Akm =:= sae orelse not SaeOnly end},
             {no_sae_ext, fun(Akm) -> Akm =/= sae orelse SaeExt end},
             {no_h2e, fun(Akm) -> Akm =/= sae orelse H2e end},
             {NoPmf, fun(Akm) -> Akm =/= sae orelse Pmf =/= none end},
             {no_secret, fun(Akm) -> own_secret(Akm, Keys) end}],
    [Akm | _] = lists:foldl(fun keep/2, [Akm || Akm <- ?PREFERRED, lists:member(Akm, Allowed)], Rules),
    {ok, Akm, Pmf}.

%% The AKMs that pass one rule; the rule's refusal when none does.
keep({Reason, Passes}, Akms) ->
    case lists:filter(Passes, Akms) of
        [] -> refuse(Reason);
        Kept -> Kept
    end.

own_secret(sae, #{sae := Sae}) -> Sae;
own_secret(_Psk, #{psk := Psk}) -> Psk.

%% PMF from the block's `ieee80211w`, the BSS's MFPC and MFPR, and whether the
%% firmware answers `mfp`: the design's table, row by row. A refusal by the BSS's
%% capabilities is `pmf_required`, one by the firmware `pmf_unavailable`.
pmf(2, #{mfpc := true}, #{mfp := true}) -> required;
pmf(2, #{mfpc := true}, #{mfp := false}) -> refuse(pmf_unavailable);
pmf(2, #{mfpc := false}, _Chip) -> refuse(pmf_required);
pmf(1, #{mfpr := true}, #{mfp := true}) -> required;
pmf(1, #{mfpr := true}, #{mfp := false}) -> refuse(pmf_unavailable);
pmf(1, #{mfpc := true}, #{mfp := true}) -> capable;
pmf(1, _Rsn, _Chip) -> none;
pmf(0, #{mfpr := true}, _Chip) -> refuse(pmf_required);
pmf(0, #{mfpr := false}, _Chip) -> none.

refuse(Reason) -> throw({refused, Reason}).
