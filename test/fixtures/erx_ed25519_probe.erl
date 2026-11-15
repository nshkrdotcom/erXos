%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ed25519_probe).

-moduledoc """
Judges `erx_bytes:ed25519_verify/3`, the BIF, in a running erXos release
(test/integration/runtime_hosted_smoke_test.rb). The host test hands `check/2` RFC 8032's
vectors (test/fixtures/ed25519_rfc8032.txt) and a signature by the host's OpenSSL over the
largest message a call takes, 65536 bytes of `16#a5`; the probe checks that the BIF accepts
each, also as binaries at a bit offset, refuses each with a bit flipped in its signature, its
key or its message and with `S + L` for `S`, and fails with `badarg` on every malformed
argument.
""".

-export([check/2]).

%% The group's order, L, of RFC 8032 section 5.1.
-define(ORDER, (1 bsl 252 + 27742317777372353535851937790883648493)).
-define(LONG_BYTE, 16#a5).
-define(CALL_MAX, 65536).

-type vector() :: {Key :: <<_:256>>, Message :: binary(), Signature :: <<_:512>>}.

-doc """
`{ed25519, Refused, Accepted, Malformed}`, where each list is empty when its check passed:
the names of valid signatures the BIF refused (`{Index, Form}`), of altered ones it accepted
(`{Index, Alteration}`), and the results of malformed calls that did not fail with `badarg`.
`Vectors` are RFC 8032's, in order; `Long` is a key and its signature over the longest
message.
""".
-spec check([vector()], {<<_:256>>, <<_:512>>}) -> {ed25519, [term()], [term()], [term()]}.
check(Vectors, {LongKey, LongSignature}) ->
    Long = {LongKey, binary:copy(<<?LONG_BYTE>>, ?CALL_MAX), LongSignature},
    Indexed = lists:enumerate([Long | Vectors]),
    {ed25519,
     [{Index, Form} || {Index, Vector} <- Indexed, {Form, Valid} <- forms(Vector), Valid =/= true],
     [{Index, Alteration} || {Index, Vector} <- Indexed, {Alteration, Valid} <- altered(Vector),
                             Valid =/= false],
     malformed(Long)}.

%% The vector as given, and with each of its three binaries at a bit offset, which the BIF
%% copies before it reads.
forms({Key, Message, Signature}) ->
    [{plain, verify(Signature, Key, Message)},
     {unaligned_signature, verify(unaligned(Signature), Key, Message)},
     {unaligned_key, verify(Signature, unaligned(Key), Message)},
     {unaligned_message, verify(Signature, Key, unaligned(Message))}].

%% The vector with its first and last bits flipped in each of its binaries, and with S + L,
%% which fits S's 32 bytes, so that only the check that S is below L refuses it.
altered({Key, Message, Signature}) ->
    <<R:32/binary, S:256/little>> = Signature,
    Flips = [{signature, Bit, verify(flip(Signature, Bit), Key, Message)} || Bit <- [0, 511]]
         ++ [{key, Bit, verify(Signature, flip(Key, Bit), Message)} || Bit <- [0, 254]]
         ++ [{message, Bit, verify(Signature, Key, flip(Message, Bit))}
             || Message =/= <<>>, Bit <- [0, bit_size(Message) - 1]],
    [{{Field, Bit}, Valid} || {Field, Bit, Valid} <- Flips]
        ++ [{s_plus_l, verify(<<R/binary, (S + ?ORDER):256/little>>, Key, Message)}].

malformed({Key, Message, Signature}) ->
    <<Short:63/binary, _/binary>> = Signature,
    <<ShortKey:31/binary, _/binary>> = Key,
    Calls = [fun() -> verify(Short, Key, Message) end,
             fun() -> verify(<<Signature/binary, 0>>, Key, Message) end,
             fun() -> verify(Signature, ShortKey, Message) end,
             fun() -> verify(Signature, <<Key/binary, 0>>, Message) end,
             fun() -> verify(Signature, Key, <<Message/binary, 0>>) end,
             fun() -> verify(<<Signature/binary, 1:7>>, Key, Message) end,
             fun() -> verify(Signature, <<Key/binary, 1:7>>, Message) end,
             fun() -> verify(Signature, Key, <<1:7>>) end,
             fun() -> verify(binary_to_list(Signature), Key, Message) end,
             fun() -> verify(Signature, binary_to_list(Key), Message) end,
             fun() -> verify(Signature, Key, "abc") end,
             fun() -> verify(Signature, Key, abc) end],
    [Result || Result <- [refused(Call) || Call <- Calls], Result =/= badarg].

refused(Call) ->
    try Call() of
        Value -> {returned, Value}
    catch
        error:badarg -> badarg;
        Class:Reason -> {Class, Reason}
    end.

verify(Signature, Key, Message) ->
    erx_bytes:ed25519_verify(Signature, Key, Message).

%% Bytes as a sub-binary three bits into a larger binary.
unaligned(Bytes) ->
    <<_:3, Unaligned:(byte_size(Bytes))/binary, _:5>> = <<0:3, Bytes/binary, 0:5>>,
    Unaligned.

flip(Bytes, Bit) ->
    <<Before:Bit/bitstring, Value:1, After/bitstring>> = Bytes,
    <<Before/bitstring, (1 - Value):1, After/bitstring>>.
