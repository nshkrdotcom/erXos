%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_wire).
-moduledoc """
The login facet's decoder of what the SSH domain hands the system domain
(docs/design-ssh.md, "Logging in", S3): every byte here came from the network, so
this module is the facet's one reader of SSH structure, and its fuzz target is
test/erlang/erx_ssh_wire_fuzz.erl.

`key_blob/1` and `signature_blob/1` compare a fixed blob whole against its one
layout (RFC 8709, sections 4 and 6): the name `ssh-ed25519` and 32 key bytes in
51 bytes, the same name and 64 signature bytes in 83. The key blob's matcher is
erx_boot_keys:key_blob/1, which the readers of root's login keys share. The
key's bytes are only bytes here; the Ed25519 verifier decodes them as a point.

`exchange/1` reads the hash input of a connection's first key exchange, at most
64 KiB, through a cursor: five length-prefixed strings (RFC 4251, section 5), each
length checked against the bytes that remain before the string is taken, and the
server's KEXINIT payload, the fourth, opening with `SSH_MSG_KEXINIT` and its
16-byte cookie (RFC 4253, section 7.1). What follows the host key differs between
exchange methods and is left unread: the facet hashes the input it was given,
never a re-encoding of these fields.

Anything else is `{error, badarg}`, which the facet answers `no_match`
(docs/design-ssh.md, "Refusals and error results"). Nothing here raises or makes
an atom.
""".

-include("generated/erx_abi.hrl").

-export([key_blob/1, signature_blob/1, exchange/1]).
-export_type([key/0, signature/0, exchange/0]).

-define(NAME_SIZE, ?ERX_SSH_ED25519_NAME_SIZE).

-type key() :: erx_boot_keys:key().
-doc "An Ed25519 signature's 64 bytes, `R` then `S`.".
-type signature() :: <<_:(?ERX_SSH_ED25519_SIGNATURE_SIZE * 8)>>.
-doc """
The five strings that open an exchange hash input (RFC 4253, section 8), by the
names of what each holds, and the cookie of the server's KEXINIT payload.
""".
-type exchange() :: #{client_version := binary(), server_version := binary(),
                      client_kexinit := binary(), server_kexinit := binary(),
                      host_key := binary(),
                      cookie := <<_:(?ERX_SSH_KEXINIT_COOKIE_SIZE * 8)>>}.

-doc "The 32 key bytes of a 51-byte `ssh-ed25519` key blob.".
-spec key_blob(term()) -> {ok, key()} | {error, badarg}.
key_blob(Blob) ->
    erx_boot_keys:key_blob(Blob).

-doc "The 64 signature bytes of an 83-byte `ssh-ed25519` signature blob.".
-spec signature_blob(term()) -> {ok, signature()} | {error, badarg}.
signature_blob(<<?NAME_SIZE:32, Name:?NAME_SIZE/binary, ?ERX_SSH_ED25519_SIGNATURE_SIZE:32,
                 Signature:?ERX_SSH_ED25519_SIGNATURE_SIZE/binary>>)
    when Name =:= ?ERX_SSH_ED25519_NAME_BYTES ->
    {ok, Signature};
signature_blob(_) ->
    {error, badarg}.

-doc """
The five strings and the server's cookie of an exchange hash input of at most
64 KiB. Every failure of a step throws `badarg`, caught here alone.
""".
-spec exchange(term()) -> {ok, exchange()} | {error, badarg}.
exchange(Input) when is_binary(Input), byte_size(Input) =< ?ERX_SSH_EXCHANGE_MAX ->
    try
        {ok, fields(Input)}
    catch
        throw:badarg -> {error, badarg}
    end;
exchange(_) ->
    {error, badarg}.

fields(Input) ->
    {ClientVersion, AfterClientVersion} = string(Input),
    {ServerVersion, AfterServerVersion} = string(AfterClientVersion),
    {ClientKexinit, AfterClientKexinit} = string(AfterServerVersion),
    {ServerKexinit, AfterServerKexinit} = string(AfterClientKexinit),
    {HostKey, _Hashed} = string(AfterServerKexinit),
    #{client_version => ClientVersion, server_version => ServerVersion,
      client_kexinit => ClientKexinit, server_kexinit => ServerKexinit,
      host_key => HostKey, cookie => cookie(ServerKexinit)}.

%% One string at the cursor and the bytes after it: its length is checked against
%% what remains before binary:part/3 takes it. The string is copied, so a field the
%% facet keeps does not keep the input, and the shared secret in it, alive.
string(<<Length:32, Rest/binary>>) when Length =< byte_size(Rest) ->
    {binary:copy(binary:part(Rest, 0, Length)), binary:part(Rest, Length, byte_size(Rest) - Length)};
string(_) ->
    throw(badarg).

cookie(<<?ERX_SSH_MSG_KEXINIT, Cookie:?ERX_SSH_KEXINIT_COOKIE_SIZE/binary, _/binary>>) ->
    Cookie;
cookie(_) ->
    throw(badarg).
