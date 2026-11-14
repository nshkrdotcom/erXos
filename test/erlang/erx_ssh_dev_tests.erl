%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_ssh_dev's daemon on stock OTP (docs/design-ssh.md, "Stages", stage 1):
%% root logs in with the login key in the keys file and runs an Erlang
%% expression, another user name with that key and root with another key are
%% refused, a key in authorized_keys2 beside the file included, an empty or
%% missing keys file admits no one, and the host key is made once, kept, and a
%% damaged one refuses the start.
-module(erx_ssh_dev_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

daemon_test_() ->
    {setup, fun start/0, fun stop/1,
     fun(Context) ->
             [?_test(root_runs_an_expression(Context)),
              ?_test(another_user_is_refused(Context)),
              ?_test(another_key_is_refused(Context)),
              ?_test(the_host_key_is_kept(Context)),
              ?_test(no_keys_admit_no_one(Context))]
     end}.

start() ->
    Work = string:trim(os:cmd("mktemp -d -t erx-ssh-dev")),
    [Keys, Host, Client, Wrong] = [filename:join(Work, Name) || Name <- ["keys", "host", "client", "wrong"]],
    ok = lists:foreach(fun(Dir) -> ok = file:make_dir(Dir) end, [Keys, Client, Wrong]),
    Public = client_key(Client),
    Login = filename:join(Keys, "authorized_keys"),
    ok = file:write_file(Login, Public),
    %% The wrong key sits beside the login key under the second name OpenSSH
    %% reads; the daemon reads exactly the file it was given.
    ok = file:write_file(filename:join(Keys, "authorized_keys2"), client_key(Wrong)),
    {ok, Daemon} = erx_ssh_dev:daemon(0, #{keys => Login, host => Host}),
    {ok, Info} = ssh:daemon_info(Daemon),
    #{work => Work, daemon => Daemon, port => proplists:get_value(port, Info),
      login => Login, host => Host, client => Client, wrong => Wrong}.

stop(#{work := Work, daemon := Daemon}) ->
    ok = ssh:stop_daemon(Daemon),
    ok = file:del_dir_r(Work).

%% A fresh Ed25519 pair: the private key as id_ed25519 in Dir, and its public
%% half as one authorized_keys line.
client_key(Dir) ->
    Private = public_key:generate_key({namedCurve, ed25519}),
    ok = file:write_file(filename:join(Dir, "id_ed25519"),
                         ssh_file:encode([{[{Private, <<>>}], []}], openssh_key_v1)),
    Public = {#'ECPoint'{point = Private#'ECPrivateKey'.publicKey}, Private#'ECPrivateKey'.parameters},
    ssh_file:encode([{Public, [{comment, ""}]}], auth_keys).

connect(#{port := Port}, User, Dir) ->
    ssh:connect("localhost", Port, [{user, User}, {user_dir, Dir}, {silently_accept_hosts, true},
                                    {save_accepted_host, false}, {user_interaction, false},
                                    {auth_methods, "publickey"}, {connect_timeout, 10000}], 10000).

root_runs_an_expression(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:exec(Connection, Channel, "lists:sum([1, 2, 3]).", 10000),
    ?assertEqual({<<"6">>, 0}, output(Connection, Channel, <<>>, undefined)),
    ok = ssh:close(Connection).

%% What the channel wrote on its standard output, and its exit status.
output(Connection, Channel, Read, Status) ->
    receive
        {ssh_cm, Connection, {data, Channel, 0, Data}} -> output(Connection, Channel, <<Read/binary, Data/binary>>, Status);
        {ssh_cm, Connection, {exit_status, Channel, Exit}} -> output(Connection, Channel, Read, Exit);
        {ssh_cm, Connection, {eof, Channel}} -> output(Connection, Channel, Read, Status);
        {ssh_cm, Connection, {closed, Channel}} -> {string:trim(Read), Status};
        {ssh_cm, Connection, Other} -> {Other, Read}
    after 10000 -> {timeout, Read}
    end.

another_user_is_refused(#{client := Client} = Context) ->
    ?assertMatch({error, _}, connect(Context, "daemon", Client)).

another_key_is_refused(#{wrong := Wrong} = Context) ->
    ?assertMatch({error, _}, connect(Context, "root", Wrong)).

the_host_key_is_kept(#{host := Host, login := Login}) ->
    Path = filename:join(Host, "ssh_host_ed25519_key"),
    {ok, Made} = file:read_file(Path),
    {ok, Again} = erx_ssh_dev:daemon(0, #{keys => Login, host => Host}),
    ok = ssh:stop_daemon(Again),
    ?assertEqual({ok, Made}, file:read_file(Path)),
    ok = file:write_file(Path, <<"not a key">>),
    ?assertMatch({error, {host_key, Path, _}}, erx_ssh_dev:daemon(0, #{keys => Login, host => Host})),
    ok = file:write_file(Path, Made).

%% With its keys file empty, or with none, the daemon admits no one, root with
%% the login key included; the file is read at each login, so one daemon shows both.
no_keys_admit_no_one(#{client := Client, login := Login} = Context) ->
    {ok, Keys} = file:read_file(Login),
    ok = file:write_file(Login, <<>>),
    ?assertMatch({error, _}, connect(Context, "root", Client)),
    ok = file:delete(Login),
    ?assertMatch({error, _}, connect(Context, "root", Client)),
    ok = file:write_file(Login, Keys),
    ?assertMatch({ok, _}, connect(Context, "root", Client)).
