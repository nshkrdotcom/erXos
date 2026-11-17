%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_fetch_tests).
-moduledoc """
The live source end to end without the internet (docs/design-quotes.md,
Q-R7, "HTTPS on the host"): erx_quotes, with its request unchanged,
fetches over HTTPS from `ssl` servers this test runs on the loopback,
with chains public_key:pkix_test_data/1 makes and their roots named by
public_key's `cacerts_path`, and sends boards as a dashboard gets them.
Every source's URL names the host `quotes.test`, which does not
resolve, and its address is 127.0.0.1, so a request reaches a server
only through the address, and the servers answer only a request whose
`host` header names `quotes.test` and its port and that asks for
`connection: close`, so httpc keeps no connection to reuse by address
alone (seeded failure: without the header every quote fails).
A server whose certificate is made for `quotes.test` gives a value,
which the name check passes only on the host name sent as SNI, never
the address; one
made for `other.test` gives `certificate rejected`; a 70,000-byte body
with its `content-length` gives `answer too big`, which max_body_size
in httpc's fourth argument alone gives (seeded failure: with it moved
into the third argument the body is taken whole).
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(DEADLINE_MS, 30000).

fetch_test_() ->
    {timeout, 60, fun fetch/0}.

fetch() ->
    {ok, _} = application:ensure_all_started(ssl),
    {Good, GoodRoot} = chain("quotes.test"),
    {Other, OtherRoot} = chain("other.test"),
    ok = file:write_file("roots.pem", public_key:pem_encode([{'Certificate', GoodRoot, not_encrypted},
                                                           {'Certificate', OtherRoot, not_encrypted}])),
    ok = application:set_env(public_key, cacerts_path, filename:absname("roots.pem")),
    GoodPort = serve(Good),
    OtherPort = serve(Other),
    Source = fun(Port, Path) ->
                     #{url => iolist_to_binary(["https://quotes.test:", integer_to_list(Port), Path]),
                       address => {127, 0, 0, 1}, format => json, price => [<<"price">>],
                       change => none, credit => <<"Local">>, note => <<>>}
             end,
    Quote = fun(S) -> {S, #{label => <<"Q">>, decimals => 2, period => 10000, sources => [S]}} end,
    Table = #{quotes => [Quote(btc), Quote(eth), Quote(big)],
              sources => #{btc => Source(GoodPort, "/btc"), eth => Source(OtherPort, "/btc"),
                           big => Source(GoodPort, "/big")}},
    {ok, Pid} = erx_quotes:start_link(self(), Table),
    Expected = #{<<"btc">> => {64412.5, <<"Local - 0 s">>},
                 <<"eth">> => {none, <<"no data: certificate rejected">>},
                 <<"big">> => {none, <<"no data: answer too big">>}},
    ?assertEqual(Expected, settled(Expected, none, erlang:monotonic_time(millisecond) + ?DEADLINE_MS)),
    unlink(Pid),
    exit(Pid, kill).

%% The quotes of the boards sent once they equal `Expected`, or the last
%% shown at the deadline.
settled(Expected, Last, Deadline) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {erx_dashboard_board, #{quotes := Quotes}} ->
            Shown = maps:from_list([{S, {P, St}} || #{symbol := S, price := P, status := St} <- Quotes]),
            case Shown =:= Expected of
                true -> Shown;
                false -> settled(Expected, Shown, Deadline)
            end
    after Wait ->
            Last
    end.

%% A server chain whose peer certificate names `Host`, as ssl's server
%% options, and its root certificate. The keys are ECDSA P-256 with SHA-256
%% signatures, as every source's were (docs/design-quotes.md, "What the
%% sources offer").
chain(Host) ->
    Name = #'Extension'{extnID = ?'id-ce-subjectAltName', critical = false,
                        extnValue = [{dNSName, Host}]},
    Key = [{key, {namedCurve, ?'secp256r1'}}, {digest, sha256}],
    #{server_config := Config} =
        public_key:pkix_test_data(#{server_chain => #{root => Key, intermediates => [],
                                                      peer => [{extensions, [Name]} | Key]},
                                    client_chain => #{root => Key, intermediates => [], peer => Key}}),
    Cacerts = proplists:get_value(cacerts, Config),
    {[{cert, proplists:get_value(cert, Config)}, {key, proplists:get_value(key, Config)}],
     lists:last(Cacerts)}.

%% An ssl server on the loopback answering `/btc` with a price and `/big`
%% with a body of 70,000 bytes and its content-length, each only to a
%% request whose host header is `quotes.test:Port` and that asks for
%% `connection: close`; its port.
serve(Options) ->
    {ok, Listen} = ssl:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}},
                                  {reuseaddr, true} | Options]),
    {ok, {_, Port}} = ssl:sockname(Listen),
    Host = iolist_to_binary(["\r\nhost: quotes.test:", integer_to_list(Port), "\r\n"]),
    spawn_link(fun() -> accept(Listen, Host) end),
    Port.

accept(Listen, Host) ->
    case ssl:transport_accept(Listen) of
        {ok, Socket} ->
            spawn(fun() -> answer(ssl:handshake(Socket, 10000), Host) end),
            accept(Listen, Host);
        {error, closed} ->
            ok
    end.

answer({ok, Socket}, Host) ->
    Head = request(Socket, <<>>),
    Lower = string:lowercase(Head),
    case {Head, binary:match(Lower, Host), binary:match(Lower, <<"\r\nconnection: close\r\n">>)} of
        {_Head, nomatch, _Close} -> ok;
        {_Head, _At, nomatch} -> ok;
        {<<"GET /btc ", _/binary>>, _At, _Close} -> reply(Socket, <<"{\"price\": \"64412.50\"}">>);
        {<<"GET /big ", _/binary>>, _At, _Close} -> reply(Socket, binary:copy(<<"x">>, 70000));
        _Other -> ok
    end,
    ssl:close(Socket);
answer({error, _Refused}, _Host) ->
    ok.

request(Socket, Head) ->
    case binary:match(Head, <<"\r\n\r\n">>) of
        nomatch ->
            case ssl:recv(Socket, 0, 10000) of
                {ok, More} -> request(Socket, <<Head/binary, More/binary>>);
                {error, _} -> Head
            end;
        _End -> Head
    end.

reply(Socket, Body) ->
    ssl:send(Socket, [<<"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ">>,
                      integer_to_binary(byte_size(Body)), <<"\r\nconnection: close\r\n\r\n">>, Body]).
