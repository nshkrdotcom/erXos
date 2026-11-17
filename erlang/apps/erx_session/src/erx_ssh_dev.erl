%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_dev).
-moduledoc """
SSH's first stage (docs/design-ssh.md, "Stages"): in a development build,
start(Port) run in root's session starts OTP's ssh daemon in that session,
through root's own `net` grant, whose session channels each run the command
shell on a tty of the session (erx_ssh_dev_channel). It is a principal
running a daemon in its own session with its own authority, and needs no
facet of its own. start/1 starts nothing unless the build facts of this
runtime's release name a development configuration
(erx_build:development_facts/1): the image build writes them into every
release, a session domain's included, and facts it cannot read count as a
release build's. Root's session runs boot/1 at boot, as the development manifest's
`-eval` asks, which starts the daemon once the session holds the facets it
needs and registers it as `erx_ssh_dev`.

Who may log in is `root`, with a key of root's: one of the medium's
`authorized_keys` (docs/design-ssh.md, "Root's login keys on the medium"),
which the session reads as 51-byte key blobs from its grant of the
`login_keys` tree, or the development login key, whose public half the
image build writes into each release of a development image at
abi/erx_abi.txt's `ssh_authorized_keys_path` under the release's root
(docs/design-ssh.md, "Login keys"). Both are read-only to the session, so
nothing it runs can add a key. This module is the daemon's key callback: it
admits those keys for the user `root` and no other name, where OTP's
`ssh_file` would read a second file beside the development one for every
user name, and it offers public keys as the only method, with at most
MAX_AUTH_TRIES failed attempts a connection, FreeBSD's `MaxAuthTries`.

The tree's file `root` is read at each login from its start, until it holds
MEDIUM_READ bytes, one past 16 keys', or meets its end, each read asking for
no more than what is left, so a server that never ends the file costs at
most that much. A file whose length is no multiple of a blob's, or past 16
keys', is refused whole and admits no key from the medium. A blob is
compared whole with the offered key's encoding, so one that is no Ed25519
key matches nothing. With no grant of `login_keys`, or a read that fails,
the medium admits no key.

The host key, Ed25519, is root's own, in HOST_DIR on root's data volume,
in OpenSSH's private key format. start/1 makes it when the file is missing
and refuses to start when the file does not decode, so the key a client
pinned never changes silently; removing the file asks for a new one. A key
it makes is written whole under another name, readable by its owner alone
where the file system keeps modes, and renamed into place.

What keeps the development key out of a release build is that its image
carries no login-key file and that start/1 refuses it. Only boot/1, start/1
and the key callback are exported, so no entry of the module as the build compiles
it names another keys file; the host tests compile it with TEST defined to
reach daemon/2, which does. The session's own authority is not narrowed by
that: any code it runs may start OTP's daemon with keys of its choosing.
""".

-behaviour(ssh_server_key_api).

-include("generated/erx_abi.hrl").

-export([boot/1, start/1]).
-export([host_key/2, is_auth_key/3]).

-ifdef(TEST).
-export([daemon/2]).
-endif.

-define(HOST_DIR, "/data/ssh").
-define(HOST_KEY, "ssh_host_ed25519_key").
-define(USER, "root").
-define(MAX_AUTH_TRIES, 6).
-define(BLOB_SIZE, (4 + ?ERX_SSH_ED25519_NAME_SIZE + 4 + ?ERX_SSH_ED25519_KEY_SIZE)).
-define(MEDIUM_KEYS_MAX, 16).
-define(MEDIUM_READ, (?MEDIUM_KEYS_MAX * ?BLOB_SIZE + 1)).
%% How boot/1 waits for the session's facets: a look every GRANT_POLL_MS, at most
%% GRANT_POLLS of them, ten minutes, after which it starts nothing.
-define(GRANT_POLL_MS, 500).
-define(GRANT_POLLS, 1200).

%% What the daemon is given: keys, the file of the development login key, one
%% `authorized_keys` line each; host, the directory of the host key, made there
%% when missing; medium, the reader of root's key blobs from the medium; and
%% open, the opener of a channel's tty (erx_ssh_dev_channel).
-type options() :: #{keys := file:filename(), host := file:filename(),
                     medium := fun(() -> {ok, binary()} | {error, term()}),
                     open := fun((pid(), erx_session_tty:channel(), fun((term()) -> term())) ->
                                        {ok, pid()} | {error, term()})}.

-doc """
Starts the daemon on Port at the session's boot (docs/design-ssh.md,
"Stages"), in a process of its own, and returns at once. The daemon listens
through the session's `net` facet and keeps its host key under `/data`,
through its `data` facet, and their domains install both some time after the
session is ready (erx:cap/1), so the process looks for the two every
GRANT_POLL_MS and then calls start/1. A daemon that started is registered as
`erx_ssh_dev`, by which a shell of the session finds it, and either way one line is
logged.
""".
-spec boot(inet:port_number()) -> ok.
boot(Port) ->
    _ = spawn(fun() -> booted(Port, start_when_granted(Port, ?GRANT_POLLS)) end),
    ok.

start_when_granted(_Port, 0) ->
    {error, {no_grant, "the session holds no net or no data facet"}};
start_when_granted(Port, Polls) ->
    case is_pid(erx:cap(net)) andalso is_pid(erx:cap(data)) of
        true ->
            start(Port);
        false ->
            timer:sleep(?GRANT_POLL_MS),
            start_when_granted(Port, Polls - 1)
    end.

booted(Port, {ok, Daemon}) ->
    true = register(?MODULE, Daemon),
    logger:notice("erx_ssh_dev: the daemon listens on port ~b", [Port]);
booted(Port, {error, Reason}) ->
    logger:notice("erx_ssh_dev: no daemon on port ~b: ~0p", [Port, Reason]).

-doc """
Starts the daemon on Port with root's login keys and host key, in a
development build; in any other it starts nothing and answers
`{error, {not_development, Why}}`.
""".
-spec start(inet:port_number()) -> {ok, ssh:daemon_ref()} | {error, term()}.
start(Port) ->
    case erx_build:development_facts(erx_build:facts()) of
        true ->
            Keys = filename:join(code:root_dir(), binary_to_list(?ERX_SSH_AUTHORIZED_KEYS_PATH_BYTES)),
            daemon(Port, #{keys => Keys, host => ?HOST_DIR, medium => fun medium_file/0,
                           open => fun erx_session_tty:open_channel/3});
        false ->
            {error, {not_development, "the release's build facts name no development build"}}
    end.

%% Starts the daemon on Port with Options (options()). Exported only to the host
%% tests (TEST), which name every option. Session channels are
%% erx_ssh_dev_channel's, and no subsystem is offered.
-spec daemon(inet:port_number(), options()) -> {ok, ssh:daemon_ref()} | {error, term()}.
daemon(Port, #{keys := Keys, host := Host, medium := Medium, open := Open}) ->
    maybe
        ok ?= host_key_file(Host),
        {ok, _} ?= application:ensure_all_started(ssh),
        ssh:daemon(Port, [{system_dir, Host},
                          {key_cb, {?MODULE, [{keys, Keys}, {medium, Medium}]}},
                          {auth_methods, "publickey"},
                          {max_auth_tries, ?MAX_AUTH_TRIES},
                          {ssh_cli, {erx_ssh_dev_channel, [Open]}},
                          {subsystems, []}])
    end.

-doc "The host key, as `ssh_file` reads it from the daemon's `system_dir`.".
host_key(Algorithm, Options) ->
    ssh_file:host_key(Algorithm, Options).

-doc """
Whether Key is one of root's login keys and User is `root`: any other user
name has none. The keys are the medium's blobs and the lines of exactly the
development file daemon/2 was given, each compared whole, so no second file
beside it adds one and nothing here writes either source.
""".
is_auth_key(Key, ?USER, Options) ->
    [{keys, File}, {medium, Medium}] = proplists:get_value(key_cb_private, Options),
    lists:member(ssh_file:encode(Key, ssh2_pubkey), medium_keys(Medium())) orelse
        case file:read_file(File) of
            {ok, Bytes} -> lists:keymember(Key, 1, ssh_file:decode(Bytes, auth_keys));
            {error, _} -> false
        end;
is_auth_key(_Key, _User, _Options) ->
    false.

%% The medium's key blobs in Read, the bytes of the tree's `root`: none when the
%% read failed or the file is no whole number of blobs within 16.
medium_keys({ok, Bytes}) when byte_size(Bytes) rem ?BLOB_SIZE =:= 0,
                              byte_size(Bytes) =< ?MEDIUM_KEYS_MAX * ?BLOB_SIZE ->
    [Blob || <<Blob:?BLOB_SIZE/binary>> <= Bytes];
medium_keys(_Read) ->
    [].

%% The tree's `root` through the session's grant of login_keys, read from its start
%% for at most MEDIUM_READ bytes, without read-ahead.
medium_file() ->
    case erx:cap(login_keys) of
        Pid when is_pid(Pid) ->
            case erx_file_remote:open({Pid, <<"login_keys">>, ro}, {target, [<<"root">>]}, [read, binary]) of
                {ok, Fd} ->
                    try read_at_most(Fd, ?MEDIUM_READ, []) after file:close(Fd) end;
                {resume, _, _} -> {error, einval};
                {error, _} = Error ->
                    Error
            end;
        undefined ->
            {error, no_grant}
    end.

read_at_most(_Fd, 0, Read) ->
    {ok, iolist_to_binary(lists:reverse(Read))};
read_at_most(Fd, Left, Read) ->
    case file:read(Fd, Left) of
        {ok, Bytes} -> read_at_most(Fd, Left - byte_size(Bytes), [Bytes | Read]);
        eof -> {ok, iolist_to_binary(lists:reverse(Read))};
        {error, _} = Error -> Error
    end.

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
