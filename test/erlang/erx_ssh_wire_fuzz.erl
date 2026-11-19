%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the login facet's decoder, erx_ssh_wire (docs/design-ssh.md,
%% "Verification"). A round writes a key blob, a signature blob and an exchange input
%% of five strings and hashed bytes, and hands each to the decoder as written,
%% mutated (bytes flipped, cut, extended, a length prefix set past the end), or
%% replaced by random bytes. Whatever arrives, the decoder never raises and makes no
%% atom; what it accepts re-encodes to its input, a blob whole and an exchange input's
%% five strings to its prefix, with the cookie bytes 1-16 of the fourth; and what was
%% written unmutated is accepted. The seed comes from make check-fuzz.

-module(erx_ssh_wire_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(NAME, <<"ssh-ed25519">>).
-define(EXCHANGE_MAX, 65536).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loaded before the first round counts atoms, since loading a module makes its atoms.
    [{module, _} = code:ensure_loaded(Module) || Module <- [erx_ssh_wire, erx_boot_keys, binary, lists, maps]],
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS * 3, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% The number of the round's three inputs the decoder accepted.
round_of() ->
    Key = blob(?NAME, rand:bytes(32)),
    Signature = blob(?NAME, rand:bytes(64)),
    Exchange = exchange(),
    lists:sum([judged(key_blob, Key), judged(signature_blob, Signature), judged(exchange, Exchange)]).

judged(Decoder, Written) ->
    {Input, Mutated} = case rand:uniform(4) of
                           1 -> {Written, false};
                           2 -> {rand:bytes(rand:uniform(byte_size(Written) + 8) - 1), true};
                           _ -> {mutated(Written), true}
                       end,
    Atoms = erlang:system_info(atom_count),
    Said = try erx_ssh_wire:Decoder(Input) catch Class:Reason -> error({raised, Decoder, Input, Class, Reason}) end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Decoder, Input}),
    case Said of
        {ok, Decoded} ->
            reencodes(Decoder, Input, Decoded) orelse error({round_trip_differs, Decoder, Input, Decoded}),
            1;
        {error, badarg} when Mutated ->
            0;
        _ ->
            error({refused_as_written, Decoder, Input, Said})
    end.

reencodes(key_blob, Input, Key) -> byte_size(Key) =:= 32 andalso blob(?NAME, Key) =:= Input;
reencodes(signature_blob, Input, Signature) -> byte_size(Signature) =:= 64 andalso blob(?NAME, Signature) =:= Input;
reencodes(exchange, Input, Fields) ->
    #{client_version := ClientVersion, server_version := ServerVersion, client_kexinit := ClientKexinit,
      server_kexinit := ServerKexinit, host_key := HostKey, cookie := Cookie} = Fields,
    Prefix = iolist_to_binary([string(Field) || Field <- [ClientVersion, ServerVersion, ClientKexinit,
                                                          ServerKexinit, HostKey]]),
    byte_size(Input) =< ?EXCHANGE_MAX andalso map_size(Fields) =:= 6
        andalso binary:longest_common_prefix([Prefix, Input]) =:= byte_size(Prefix)
        andalso binary:part(ServerKexinit, 0, min(17, byte_size(ServerKexinit))) =:= <<20, Cookie/binary>>.

%% Five strings with short random contents, the fourth a server KEXINIT, then hashed
%% bytes: none, a few, or enough to bring the input to the 64 KiB bound or past it.
exchange() ->
    Fields = [rand:bytes(rand:uniform(40) - 1), rand:bytes(rand:uniform(40) - 1),
              <<20, (rand:bytes(rand:uniform(60) + 15))/binary>>,
              <<20, (rand:bytes(rand:uniform(60) + 15))/binary>>, blob(?NAME, rand:bytes(32))],
    Prefix = iolist_to_binary([string(Field) || Field <- Fields]),
    Hashed = case rand:uniform(8) of
                 1 -> <<>>;
                 2 -> binary:copy(<<0>>, ?EXCHANGE_MAX - byte_size(Prefix));
                 _ -> rand:bytes(rand:uniform(200))
             end,
    <<Prefix/binary, Hashed/binary>>.

mutated(<<>>) -> rand:bytes(rand:uniform(8));
mutated(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Bytes,
    case rand:uniform(5) of
        1 -> <<Before/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), After/binary>>;
        2 -> Before;
        3 -> <<Bytes/binary, (rand:bytes(rand:uniform(4)))/binary>>;
        4 -> <<Before/binary, (rand:uniform(256) - 1):8, 0:24, After/binary>>;
        5 -> past_end(Bytes, At)
    end.

%% A 32-bit length at At set to one past the bytes after it, or to the largest one.
past_end(Bytes, At) when At + 4 =< byte_size(Bytes) ->
    <<Before:At/binary, _:32, After/binary>> = Bytes,
    Length = case rand:uniform(2) of 1 -> byte_size(After) + 1; 2 -> 16#FFFFFFFF end,
    <<Before/binary, Length:32, After/binary>>;
past_end(Bytes, _At) ->
    binary:part(Bytes, 0, byte_size(Bytes) - 1).

string(Bytes) -> <<(byte_size(Bytes)):32, Bytes/binary>>.

blob(Name, Bytes) -> <<(string(Name))/binary, (string(Bytes))/binary>>.
