%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_http_tests).
-moduledoc """
EUnit cases of the classifier (docs/design-quotes.md, "Verification and
testing", the classify test): each status, redirect and error shape of
the reasons table, built as httpc and ssl answer, maps to its reason;
redirects that leave the origin are refused, a relative one followed and
a fourth hop refused; `retry-after` values give their delays; an expired
certificate on an unset clock is `clock_unset`. Seeded failure:
following a redirect without comparing its host turns the other-host
case into `follow`.
""".

-include_lib("eunit/include/eunit.hrl").

-define(URL, <<"https://quotes.test/api/btc">>).
-define(Y1970, 300).          % 1970-01-01T00:05:00Z
-define(Y2026, 1794700800).   % 2026-11-15T00:00:00Z

classify(Result) ->
    erx_quotes_http:classify(Result, ?URL, 0, ?Y2026).

answer(Code, Headers) ->
    {{"HTTP/1.1", Code, "Phrase"}, Headers, <<"body">>}.

failed_connect(Reason) ->
    {error, {failed_connect, [{to_address, {"quotes.test", 443}},
                              {inet, [inet], Reason}]}}.

body_test() ->
    ?assertEqual({body, <<"body">>}, classify(answer(200, []))).

status_test() ->
    [?assertEqual({error, {status, Code}, none}, classify(answer(Code, [])))
     || Code <- [204, 304, 400, 404, 429, 500, 503]],
    ?assertEqual({error, failed, none}, classify(answer(1000, []))),
    ?assertEqual({error, failed, none}, classify(answer(99, []))).

error_shapes_test() ->
    Cases = [{failed_connect(eacces), no_net},
             {failed_connect(nxdomain), dns},
             {failed_connect(econnrefused), connect},
             {failed_connect(ehostunreach), connect},
             {failed_connect(enetunreach), connect},
             {failed_connect(timeout), connect},
             {{error, timeout}, timeout},
             {{error, body_too_big}, too_big},
             {{error, {header_too_long, {max, 10240}}}, too_big},
             {failed_connect({tls_alert, {handshake_failure, "x"}}), tls},
             {failed_connect({tls_alert, {protocol_version, "x"}}), tls},
             {failed_connect(einval), failed},
             {{error, socket_closed_remotely}, failed},
             {{error, {failed_connect, garbage}}, failed},
             {weird, failed},
             {{{"HTTP/1.1", 200, "OK"}, [], "a list body"}, failed}],
    [?assertEqual({error, Reason, none}, classify(Result)) || {Result, Reason} <- Cases].

certificate_test() ->
    Alerts = [bad_certificate, unsupported_certificate, certificate_revoked,
              certificate_expired, certificate_unknown, unknown_ca],
    [?assertEqual({error, certificate, none},
                  classify(failed_connect({tls_alert, {Alert, "description"}})))
     || Alert <- Alerts].

clock_test() ->
    Expired = failed_connect({tls_alert, {certificate_expired, "expired"}}),
    Unknown = failed_connect({tls_alert, {unknown_ca, "unknown"}}),
    ?assertEqual({error, clock_unset, none}, erx_quotes_http:classify(Expired, ?URL, 0, ?Y1970)),
    ?assertEqual({error, certificate, none}, erx_quotes_http:classify(Expired, ?URL, 0, ?Y2026)),
    ?assertEqual({error, certificate, none}, erx_quotes_http:classify(Unknown, ?URL, 0, ?Y1970)).

redirect(Location, Hops) ->
    erx_quotes_http:classify(answer(307, [{"location", Location}]), ?URL, Hops, ?Y2026).

redirect_test() ->
    ?assertEqual({follow, <<"https://quotes.test/v2/btc">>}, redirect("/v2/btc", 0)),
    ?assertEqual({follow, <<"https://quotes.test/api/eth">>}, redirect("eth", 0)),
    ?assertEqual({follow, <<"https://QUOTES.test:443/x">>}, redirect("https://QUOTES.test:443/x", 2)),
    [?assertEqual({error, redirect, none}, redirect(Location, 0))
     || Location <- ["http://quotes.test/api/btc", "https://other.test/api/btc",
                     "https://quotes.test:8443/api/btc", "//other.test/x",
                     "ftp://quotes.test/x", [16#100, $x]]],
    ?assertEqual({error, redirect, none}, redirect("/v2/btc", 3)),
    [?assertEqual({error, redirect, none},
                  erx_quotes_http:classify(answer(Code, Headers), ?URL, 0, ?Y2026))
     || Code <- [301, 302, 303, 307, 308],
        Headers <- [[], [{"location", "/a"}, {"location", "/b"}]]].

retry_after_test() ->
    Cases = [{"0", none}, {"1", 1000}, {"3600", 3600000}, {"7200", 3600000},
             {"12345678901", none}, {"9999999999", 3600000}, {" 120 ", 120000},
             {"Wed, 21 Oct 2026 07:28:00 GMT", none}, {"-5", none}, {"1.5", none}, {"", none}],
    [begin
         ?assertEqual({error, {status, 429}, Delay}, classify(answer(429, [{"retry-after", Value}]))),
         ?assertEqual({error, {status, 503}, Delay}, classify(answer(503, [{"retry-after", Value}])))
     end || {Value, Delay} <- Cases],
    ?assertEqual({error, {status, 500}, none}, classify(answer(500, [{"retry-after", "60"}]))),
    ?assertEqual({error, {status, 429}, none},
                 classify(answer(429, [{"retry-after", "1"}, {"retry-after", "2"}]))).

word_test() ->
    ?assertEqual(<<"HTTP 503">>, erx_quotes_http:word({status, 503})),
    ?assertEqual(<<"clock not set">>, erx_quotes_http:word(clock_unset)),
    ?assertEqual(<<"certificate rejected">>, erx_quotes_http:word(certificate)).
