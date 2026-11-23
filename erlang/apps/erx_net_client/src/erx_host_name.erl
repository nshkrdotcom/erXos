%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_host_name).
-moduledoc """
The one host-name rule of erXos's network code (docs/design-network-stack.md, "Name
resolution"), which the resolver's check of the grant's answer (erx_inet), the DHCP
client's search list (erx_dhcp4_wire) and the NTP server list (erx_ntp_exchange) apply.
It is pure: no process, no state and no authority.

host_name/1 takes a binary of labels joined by dots, each label 1 to 63 letters, digits
and hyphens that begins and ends with a letter or digit, as `res_hnok` takes them (RFC
1123 section 2.1), at most 253 bytes (RFC 1035 section 2.3.4), and no trailing dot. That
is stricter than `res_hnok`, which also takes an empty label, since inet_dns cannot
encode one and would fail the caller's query. domain/1 is the rule for a search domain,
a resolver's and a DHCP server's: one trailing dot allowed and dropped, the rest a host
name. A name that passes holds no byte a terminal acts on.
""".

-export([host_name/1, domain/1]).

-define(MAX_NAME, 253).

-doc "Whether Name is a host name: labels of `res_hnok`, 253 bytes in all, no trailing dot.".
-spec host_name(term()) -> boolean().
host_name(Name) when is_binary(Name), byte_size(Name) =< ?MAX_NAME ->
    lists:all(fun label/1, binary:split(Name, <<".">>, [global]));
host_name(_) ->
    false.

-doc "A search domain without its one optional trailing dot; `error` unless the rest is a host name.".
-spec domain(term()) -> {ok, binary()} | error.
domain(Name) when is_binary(Name) ->
    Bare = case Name of
               <<Head:(byte_size(Name) - 1)/binary, $.>> -> Head;
               _ -> Name
           end,
    case host_name(Bare) of
        true -> {ok, Bare};
        false -> error
    end;
domain(_) ->
    error.

label(Label) when byte_size(Label) >= 1, byte_size(Label) =< 63 ->
    border(binary:first(Label)) andalso border(binary:last(Label))
        andalso lists:all(fun(C) -> border(C) orelse C =:= $- end, binary_to_list(Label));
label(_) ->
    false.

border(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9).
