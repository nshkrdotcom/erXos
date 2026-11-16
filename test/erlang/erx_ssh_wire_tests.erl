%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The login facet's decoder, erx_ssh_wire (docs/design-ssh.md, "Logging in", S3,
%% and "Verification"): the blobs it accepts and refuses, and the exchange input's
%% five strings, each length checked against what remains. This module writes its
%% own SSH strings (RFC 4251, section 5), so a decoding is checked against an
%% encoder that shares no code with it.

-module(erx_ssh_wire_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NAME, <<"ssh-ed25519">>).
-define(KEXINIT, 20).

string(Bytes) -> <<(byte_size(Bytes)):32, Bytes/binary>>.

blob(Name, Bytes) -> <<(string(Name))/binary, (string(Bytes))/binary>>.

server_kexinit(Cookie) -> <<?KEXINIT, Cookie/binary, "name-lists">>.

%% Five strings, as a client and a server would hash them, then Hashed.
input(Fields, Hashed) -> iolist_to_binary([[string(Field) || Field <- Fields], Hashed]).

cookie() -> binary:copy(<<16#c5>>, 16).

fields() ->
    [<<"SSH-2.0-OpenSSH_9.9">>, <<"SSH-2.0-Erlang/5.2">>, <<?KEXINIT, 0:128, "client">>,
     server_kexinit(cookie()), blob(?NAME, binary:copy(<<7>>, 32))].

decoded([ClientVersion, ServerVersion, ClientKexinit, ServerKexinit, HostKey]) ->
    #{client_version => ClientVersion, server_version => ServerVersion,
      client_kexinit => ClientKexinit, server_kexinit => ServerKexinit,
      host_key => HostKey, cookie => cookie()}.

a_key_blob_decodes_to_its_key_test() ->
    Key = binary:copy(<<16#a5>>, 32),
    ?assertEqual(51, byte_size(blob(?NAME, Key))),
    ?assertEqual({ok, Key}, erx_ssh_wire:key_blob(blob(?NAME, Key))).

a_key_blob_of_another_length_or_name_is_refused_test() ->
    Blob = blob(?NAME, binary:copy(<<1>>, 32)),
    [?assertEqual({error, badarg}, erx_ssh_wire:key_blob(Refused), Refused)
     || Refused <- [binary:part(Blob, 0, 50), <<Blob/binary, 0>>, <<>>,
                    blob(<<"ssh-ed25518">>, binary:copy(<<1>>, 32)),
                    blob(<<"ssh-ed448">>, binary:copy(<<1>>, 32)),
                    blob(?NAME, binary:copy(<<1>>, 31)),
                    blob(?NAME, binary:copy(<<1>>, 64)),
                    <<11:32, ?NAME/binary, 33:32, (binary:copy(<<1>>, 31))/binary>>,
                    <<Blob/binary, 1:1>>, binary_to_list(Blob), not_a_blob]].

a_signature_blob_decodes_to_its_signature_test() ->
    Signature = binary:copy(<<16#5a>>, 64),
    ?assertEqual(83, byte_size(blob(?NAME, Signature))),
    ?assertEqual({ok, Signature}, erx_ssh_wire:signature_blob(blob(?NAME, Signature))).

a_signature_blob_of_another_length_or_name_is_refused_test() ->
    Blob = blob(?NAME, binary:copy(<<1>>, 64)),
    [?assertEqual({error, badarg}, erx_ssh_wire:signature_blob(Refused), Refused)
     || Refused <- [binary:part(Blob, 0, 82), <<Blob/binary, 0>>, <<>>,
                    blob(<<"rsa-sha2-256">>, binary:copy(<<1>>, 64)),
                    blob(?NAME, binary:copy(<<1>>, 32)),
                    blob(?NAME, binary:copy(<<1>>, 63)), {Blob}]].

an_exchange_input_decodes_to_its_five_strings_and_the_cookie_test() ->
    ?assertEqual({ok, decoded(fields())},
                 erx_ssh_wire:exchange(input(fields(), [string(<<"e">>), string(<<"f">>), <<0, 0, 0, 33, 7>>]))).

an_input_of_exactly_five_strings_decodes_test() ->
    ?assertEqual({ok, decoded(fields())}, erx_ssh_wire:exchange(input(fields(), []))),
    Empty = [<<>>, <<>>, <<>>, server_kexinit(cookie()), <<>>],
    ?assertEqual({ok, decoded(Empty)}, erx_ssh_wire:exchange(input(Empty, []))).

an_input_of_64_kib_decodes_and_one_byte_more_is_refused_test() ->
    Prefix = input(fields(), []),
    Fill = binary:copy(<<0>>, 65536 - byte_size(Prefix)),
    ?assertMatch({ok, _}, erx_ssh_wire:exchange(<<Prefix/binary, Fill/binary>>)),
    ?assertEqual({error, badarg}, erx_ssh_wire:exchange(<<Prefix/binary, Fill/binary, 0>>)).

%% At each of the five strings in turn: a length one past what remains, and the
%% largest length a prefix can say.
a_length_past_the_end_is_refused_test() ->
    Fields = fields(),
    [begin
         Before = input(lists:sublist(Fields, At - 1), []),
         Remaining = iolist_to_binary([lists:nthtail(At - 1, Fields)]),
         [?assertEqual({error, badarg},
                       erx_ssh_wire:exchange(<<Before/binary, Length:32, Remaining/binary>>), {At, Length})
          || Length <- [byte_size(Remaining) + 1, 16#FFFFFFFF]]
     end || At <- lists:seq(1, 5)].

an_input_short_of_five_strings_is_refused_test() ->
    Fields = fields(),
    [?assertEqual({error, badarg}, erx_ssh_wire:exchange(Input), Input)
     || Input <- [<<>>, <<0, 0, 0>>, input(lists:sublist(Fields, 4), []),
                  <<(input(lists:sublist(Fields, 4), []))/binary, 0, 0>>]].

a_server_kexinit_without_its_message_number_and_cookie_is_refused_test() ->
    [Client, Server, ClientKexinit, _, HostKey] = fields(),
    [?assertEqual({error, badarg}, erx_ssh_wire:exchange(input([Client, Server, ClientKexinit, Kexinit, HostKey], [])),
                  Kexinit)
     || Kexinit <- [<<21, (cookie())/binary>>, <<0, (cookie())/binary, "x">>, <<?KEXINIT>>,
                    <<?KEXINIT, (binary:part(cookie(), 0, 15))/binary>>, <<>>]],
    Bare = [Client, Server, ClientKexinit, <<?KEXINIT, (cookie())/binary>>, HostKey],
    ?assertMatch({ok, #{cookie := <<16#c5, _:15/binary>>}}, erx_ssh_wire:exchange(input(Bare, []))).

anything_but_a_binary_is_refused_test() ->
    [?assertEqual({error, badarg}, erx_ssh_wire:exchange(Term), Term)
     || Term <- [binary_to_list(input(fields(), [])), <<(input(fields(), []))/binary, 1:3>>, 0, #{}]].
