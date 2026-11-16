%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_ssh_dev's daemon on stock OTP (docs/design-ssh.md, "Stages", stage 1):
%% root logs in with the development key or a key of the medium's, gets a
%% shell on a tty whose size and ending reach the channel, and has exec
%% refused; another user name with that key and root with another key are
%% refused, a key in authorized_keys2 beside the file included, an empty or
%% missing keys file admits no one, a medium file of another length than whole
%% blobs admits none of its keys, the host key is made once, owner-only and
%% whole, kept, and a damaged one refuses the start, and start/1 refuses a
%% runtime whose release is not a development build's. The tty is a stand-in
%% (tty/3) that speaks the six messages: it reports its size and TERM as
%% output, echoes input, ends with the status `exit N` names and with sigint
%% on Ctrl-C, as the session's line discipline would. The work directory is
%% ERX_SSH_DEV_WORK, which the host test makes and removes.
-module(erx_ssh_dev_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

daemon_test_() ->
    {setup, fun start/0, fun stop/1,
     fun(Context) ->
             [?_test(a_shell_runs_on_a_tty(Context)),
              ?_test(ctrl_c_ends_with_int(Context)),
              ?_test(exec_is_refused(Context)),
              ?_test(root_logs_in_with_a_card_key(Context)),
              ?_test(a_card_file_of_another_length_admits_none(Context)),
              ?_test(another_user_is_refused(Context)),
              ?_test(another_key_is_refused(Context)),
              ?_test(the_host_key_is_kept(Context)),
              ?_test(no_keys_admit_no_one(Context)),
              ?_test(the_host_key_is_owner_only(Context)),
              ?_test(an_existing_directory_is_narrowed(Context))]
     end}.

%% Stock OTP's release has no build facts, so it is not a development build's.
start_refuses_a_release_build_test() ->
    ?assertMatch({error, {not_development, _}}, erx_ssh_dev:start(0)).

%% The build kind start/1 takes from build facts as the image build writes them:
%% only a development configuration is a development build.
the_build_kind_test() ->
    Facts = fun(Configuration) ->
                    {ok, _} = erx_build:parse_facts(<<"revision unknown\ndate unknown\nconfiguration ",
                                                      Configuration/binary, "\nkernel unknown\n">>)
            end,
    ?assertEqual([{development, true}, {local, true}, {release, false}, {release_local, false}, {unknown, false},
                  {none, false}],
                 [{development, erx_build:development_facts(Facts(<<"qemu-virt/development">>))},
                  {local, erx_build:development_facts(Facts(<<"qemu-virt/development-local">>))},
                  {release, erx_build:development_facts(Facts(<<"qemu-virt/release">>))},
                  {release_local, erx_build:development_facts(Facts(<<"qemu-virt/release-local">>))},
                  {unknown, erx_build:development_facts(Facts(<<"unknown">>))},
                  {none, erx_build:development_facts({error, {no_facts, "none"}})}]).

start() ->
    Work = os:getenv("ERX_SSH_DEV_WORK"),
    [Keys, Host, Client, Wrong, Card] = [filename:join(Work, Name) || Name <- ["keys", "host", "client", "wrong", "card"]],
    ok = lists:foreach(fun(Dir) -> ok = file:make_dir(Dir) end, [Keys, Client, Wrong, Card]),
    Public = client_key(Client),
    Login = filename:join(Keys, "authorized_keys"),
    ok = file:write_file(Login, Public),
    %% The wrong key sits beside the login key under the second name OpenSSH
    %% reads; the daemon reads exactly the file it was given.
    ok = file:write_file(filename:join(Keys, "authorized_keys2"), client_key(Wrong)),
    %% The medium's tree holds the card key's blob, as the storage domain serves it.
    [{CardKey, _}] = ssh_file:decode(client_key(Card), auth_keys),
    ok = file:write_file(medium(Work), ssh_file:encode(CardKey, ssh2_pubkey)),
    {ok, Daemon} = erx_ssh_dev:daemon(0, options(Login, Host)),
    {ok, Info} = ssh:daemon_info(Daemon),
    #{work => Work, daemon => Daemon, port => proplists:get_value(port, Info),
      login => Login, host => Host, client => Client, wrong => Wrong, card => Card}.

%% The daemon's options with the stand-in tty and the medium's file in the work directory.
options(Login, Host) ->
    Medium = medium(os:getenv("ERX_SSH_DEV_WORK")),
    #{keys => Login, host => Host, medium => fun() -> file:read_file(Medium) end, open => fun tty/3}.

medium(Work) -> filename:join(Work, "medium_root").

%% The stand-in tty: it names itself to the channel, reports its size and TERM, and
%% then answers the channel's messages until the channel ends, its hangup.
tty(Channel, #{run := shell, size := {Rows, Columns}, vars := #{<<"TERM">> := [Term]}}, Notify) ->
    {ok, spawn(fun() ->
                       Ref = monitor(process, Channel),
                       Channel ! {tty_open, self()},
                       Channel ! {tty_output, 0, iolist_to_binary(io_lib:format("size ~b ~b ~s\r\n", [Rows, Columns, Term]))},
                       tty_loop(Channel, Ref, Notify, 1)
               end)}.

tty_loop(Channel, Ref, Notify, N) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok;
        {tty_taken, _} -> tty_loop(Channel, Ref, Notify, N);
        {tty_size, Rows, Columns} ->
            Channel ! {tty_output, N, iolist_to_binary(io_lib:format("size ~b ~b\r\n", [Rows, Columns]))},
            tty_loop(Channel, Ref, Notify, N + 1);
        {tty_input, <<3>>} -> Notify({signaled, sigint});
        {tty_input, <<"exit ", Status/binary>>} -> Notify({exited, binary_to_integer(Status)});
        {tty_input, Bytes} ->
            Channel ! {tty_output, N, Bytes},
            tty_loop(Channel, Ref, Notify, N + 1)
    end.

stop(#{daemon := Daemon}) ->
    ok = ssh:stop_daemon(Daemon).

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

%% A pty-req's size reaches the tty, a window change resizes it, input reaches it
%% and its output the client, and the status the shell ends with is the channel's.
a_shell_runs_on_a_tty(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:ptty_alloc(Connection, Channel, [{term, "vt100"}, {width, 100}, {height, 30}], 10000),
    %% Input sent right after the shell request, as OpenSSH sends it, reaches the tty.
    ok = ssh_connection:shell(Connection, Channel),
    ok = ssh_connection:send(Connection, Channel, <<"ps\n">>),
    ?assertMatch({ok, <<"size 30 100 ", _/binary>>}, data(Connection, Channel)),
    ?assertEqual({ok, <<"ps\n">>}, data(Connection, Channel)),
    ok = ssh_connection:window_change(Connection, Channel, 120, 40),
    ?assertEqual({ok, <<"size 40 120\r\n">>}, data(Connection, Channel)),
    ok = ssh_connection:send(Connection, Channel, <<"exit 3">>),
    ?assertEqual({<<>>, {status, 3}}, ending(Connection, Channel, <<>>, none)),
    ok = ssh:close(Connection).

ctrl_c_ends_with_int(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:ptty_alloc(Connection, Channel, [], 10000),
    ok = ssh_connection:shell(Connection, Channel),
    {ok, _Size} = data(Connection, Channel),
    ok = ssh_connection:send(Connection, Channel, <<3>>),
    ?assertEqual({<<>>, {signal, "INT"}}, ending(Connection, Channel, <<>>, none)),
    ok = ssh:close(Connection).

exec_is_refused(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:exec(Connection, Channel, "ps", 10000),
    ?assertEqual({<<"exec is not supported in 0.1\r\n">>, {status, 1}}, ending(Connection, Channel, <<>>, none)),
    ok = ssh:close(Connection).

%% A key of the medium's logs root in, and no other user name; with the medium's file
%% one byte longer than its blob, none of it does.
root_logs_in_with_a_card_key(#{card := Card} = Context) ->
    {ok, Connection} = connect(Context, "root", Card),
    ok = ssh:close(Connection),
    ?assertMatch({error, _}, connect(Context, "daemon", Card)).

a_card_file_of_another_length_admits_none(#{card := Card, work := Work} = Context) ->
    {ok, Blob} = file:read_file(medium(Work)),
    ok = file:write_file(medium(Work), <<Blob/binary, 0>>),
    ?assertMatch({error, _}, connect(Context, "root", Card)),
    ok = file:write_file(medium(Work), Blob).

%% The next data the channel sent on its standard output.
data(Connection, Channel) ->
    receive
        {ssh_cm, Connection, {data, Channel, 0, Data}} -> {ok, Data}
    after 10000 -> timeout
    end.

%% What the channel wrote on its standard error, and how it ended, once it closed.
ending(Connection, Channel, Error, Ending) ->
    receive
        {ssh_cm, Connection, {data, Channel, 1, Data}} -> ending(Connection, Channel, <<Error/binary, Data/binary>>, Ending);
        {ssh_cm, Connection, {exit_status, Channel, Status}} -> ending(Connection, Channel, Error, {status, Status});
        {ssh_cm, Connection, {exit_signal, Channel, Signal, _, _}} -> ending(Connection, Channel, Error, {signal, Signal});
        {ssh_cm, Connection, {eof, Channel}} -> ending(Connection, Channel, Error, Ending);
        {ssh_cm, Connection, {closed, Channel}} -> {Error, Ending};
        {ssh_cm, Connection, Other} -> {Other, Ending}
    after 10000 -> {timeout, Ending}
    end.

another_user_is_refused(#{client := Client} = Context) ->
    ?assertMatch({error, _}, connect(Context, "daemon", Client)).

another_key_is_refused(#{wrong := Wrong} = Context) ->
    ?assertMatch({error, _}, connect(Context, "root", Wrong)).

the_host_key_is_kept(#{host := Host, login := Login}) ->
    Path = filename:join(Host, "ssh_host_ed25519_key"),
    {ok, Made} = file:read_file(Path),
    {ok, Again} = erx_ssh_dev:daemon(0, options(Login, Host)),
    ok = ssh:stop_daemon(Again),
    ?assertEqual({ok, Made}, file:read_file(Path)),
    ok = file:write_file(Path, <<"not a key">>),
    ?assertMatch({error, {host_key, Path, _}}, erx_ssh_dev:daemon(0, options(Login, Host))),
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

%% The made key's directory is 0700 and the key 0600, on a file system that
%% keeps modes, and nothing but the key is left beside it: the name it was
%% written under has been renamed.
the_host_key_is_owner_only(#{host := Host}) ->
    {ok, #file_info{mode = Dir}} = file:read_file_info(Host),
    {ok, #file_info{mode = Key}} = file:read_file_info(filename:join(Host, "ssh_host_ed25519_key")),
    ?assertEqual({8#700, 8#600}, {Dir band 8#777, Key band 8#777}),
    ?assertEqual({ok, ["ssh_host_ed25519_key"]}, file:list_dir(Host)).


%% A host-key directory that is there already is narrowed to 0700 as well.
an_existing_directory_is_narrowed(#{work := Work, login := Login}) ->
    Host = filename:join(Work, "existing"),
    ok = file:make_dir(Host),
    ok = file:change_mode(Host, 8#755),
    {ok, Daemon} = erx_ssh_dev:daemon(0, options(Login, Host)),
    ok = ssh:stop_daemon(Daemon),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Host),
    ?assertEqual(8#700, Mode band 8#777).
