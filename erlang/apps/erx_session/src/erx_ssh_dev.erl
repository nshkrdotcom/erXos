%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_dev).
-moduledoc """
SSH's first stage (docs/design-ssh.md, "Stages"): in a development build,
start(Port) run in root's session starts OTP's ssh daemon in that session,
through root's own `net` grant, with OTP's Erlang shell. It is a principal
running a daemon in its own session with its own authority, and needs no
facet of its own. start/1 starts nothing unless the build facts of this
runtime's release name a development configuration
(erx_build:development_facts/1): the image build writes them into every
release, a session domain's included, and facts it cannot read count as a
release build's.

Who may log in is the development login key alone: the image build writes
its public half into each release of a development image, at
abi/erx_abi.txt's `ssh_authorized_keys_path` under the release's root, and
the packer refuses that file in any other build (docs/design-ssh.md, "Login
keys"). The release is read-only, so nothing the session runs can add a
key. This module is the daemon's key callback: it admits that key for the
user `root` and no other name, reading that one file, where OTP's `ssh_file`
would read a second file beside it for every user name, and it offers public
keys as the only method, with at most MAX_AUTH_TRIES failed attempts a
connection, FreeBSD's `MaxAuthTries`.

The host key, Ed25519, is root's own, in HOST_DIR on root's data volume,
in OpenSSH's private key format. start/1 makes it when the file is missing
and refuses to start when the file does not decode, so the key a client
pinned never changes silently; removing the file asks for a new one. A key
it makes is written whole under another name, readable by its owner alone
where the file system keeps modes, and renamed into place.

What keeps the development key out of a release build is that its image
carries no login-key file and that start/1 refuses it. Only start/1 and the
key callback are exported, so no entry of the module as the build compiles
it names another keys file; the host tests compile it with TEST defined to
reach daemon/2, which does. The session's own authority is not narrowed by
that: any code it runs may start OTP's daemon with keys of its choosing.
""".

-behaviour(ssh_server_key_api).

-include("generated/erx_abi.hrl").

-export([start/1]).
-export([host_key/2, is_auth_key/3]).

-ifdef(TEST).
-export([daemon/2]).
-endif.

-define(HOST_DIR, "/data/ssh").
-define(HOST_KEY, "ssh_host_ed25519_key").
-define(USER, "root").
-define(MAX_AUTH_TRIES, 6).

-doc """
Starts the daemon on Port with the release's login key and root's host
key, in a development build; in any other it starts nothing and answers
`{error, {not_development, Why}}`.
""".
-spec start(inet:port_number()) -> {ok, ssh:daemon_ref()} | {error, term()}.
start(Port) ->
    case erx_build:development_facts(erx_build:facts()) of
        true ->
            Keys = filename:join(code:root_dir(), binary_to_list(?ERX_SSH_AUTHORIZED_KEYS_PATH_BYTES)),
            daemon(Port, #{keys => Keys, host => ?HOST_DIR});
        false ->
            {error, {not_development, "the release's build facts name no development build"}}
    end.

%% Starts the daemon on Port: keys is the file of root's login keys, one
%% `authorized_keys` line each, and host the directory of the host key, which
%% is made there when missing. Exported only to the host tests (TEST), which
%% name both.
-spec daemon(inet:port_number(), #{keys := file:filename(), host := file:filename()}) ->
          {ok, ssh:daemon_ref()} | {error, term()}.
daemon(Port, #{keys := Keys, host := Host}) ->
    maybe
        ok ?= host_key_file(Host),
        {ok, _} ?= application:ensure_all_started(ssh),
        ssh:daemon(Port, [{system_dir, Host},
                          {key_cb, {?MODULE, [{keys, Keys}]}},
                          {auth_methods, "publickey"},
                          {max_auth_tries, ?MAX_AUTH_TRIES},
                          {shell, {shell, start, []}},
                          {exec, erlang_eval}])
    end.

-doc "The host key, as `ssh_file` reads it from the daemon's `system_dir`.".
host_key(Algorithm, Options) ->
    ssh_file:host_key(Algorithm, Options).

-doc """
Whether Key is one of root's login keys and User is `root`: any other user
name has none. The keys are the lines of exactly the file daemon/2 was
given, compared whole, so no second file beside it adds one and nothing
here touches the read-only release.
""".
is_auth_key(Key, ?USER, Options) ->
    [{keys, File}] = proplists:get_value(key_cb_private, Options),
    case file:read_file(File) of
        {ok, Bytes} -> lists:keymember(Key, 1, ssh_file:decode(Bytes, auth_keys));
        {error, _} -> false
    end;
is_auth_key(_Key, _User, _Options) ->
    false.

%% The host key file in Dir: one that decodes is kept, a missing one is made,
%% and one that does not decode stops the start. It is read as the daemon reads
%% it, through ssh_file.
host_key_file(Dir) ->
    Path = filename:join(Dir, ?HOST_KEY),
    case file:read_file_info(Path) of
        {ok, _} ->
            case ssh_file:host_key('ssh-ed25519', [{system_dir, Dir}]) of
                {ok, _Key} -> ok;
                {error, _} -> {error, {host_key, Path, "does not decode; remove it to make a new one"}}
            end;
        {error, enoent} ->
            make_host_key(Dir, Path);
        {error, Reason} ->
            {error, {host_key, Path, Reason}}
    end.

%% A new key, written whole and synced under a name of its own beside Path,
%% then renamed to Path, so a write that fails or stops part way leaves no file
%% at Path; a failed one deletes its file. Dir is 0700 and the file 0600 before
%% any byte of the key is written, where the file system keeps modes. Two starts
%% racing on a missing key each make one, and the later rename wins.
make_host_key(Dir, Path) ->
    Key = public_key:generate_key({namedCurve, ed25519}),
    Bytes = ssh_file:encode([{[{Key, <<>>}], []}], openssh_key_v1),
    New = Path ++ ".new." ++ integer_to_list(erlang:unique_integer([positive])),
    maybe
        ok ?= host_key_error(Dir, owner_only_dir(Dir)),
        ok ?= host_key_error(New, write_owner_only(New, Bytes)),
        host_key_error(Path, file:rename(New, Path))
    else
        {error, _} = Error ->
            _ = file:delete(New),
            Error
    end.

host_key_error(_Path, ok) -> ok;
host_key_error(Path, {error, Reason}) -> {error, {host_key, Path, Reason}}.

owner_only_dir(Dir) ->
    case file:make_dir(Dir) of
        Made when Made =:= ok; Made =:= {error, eexist} -> kept_modes(file:change_mode(Dir, 8#700));
        {error, _} = Error -> Error
    end.

%% The file is closed whatever happens, and the first error is the answer.
write_owner_only(Path, Bytes) ->
    maybe
        {ok, Device} ?= file:open(Path, [write, binary]),
        Written = maybe
                      ok ?= kept_modes(file:change_mode(Path, 8#600)),
                      ok ?= file:write(Device, Bytes),
                      file:sync(Device)
                  end,
        Closed = file:close(Device),
        ok ?= Written,
        Closed
    end.

%% A file server that keeps no modes may refuse a change of them with enotsup
%% (littlefs's file server accepts one and keeps nothing); its files have no
%% modes to narrow.
kept_modes(ok) -> ok;
kept_modes({error, enotsup}) -> ok;
kept_modes({error, _} = Error) -> Error.
