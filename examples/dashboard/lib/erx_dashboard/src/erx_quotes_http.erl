%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_http).
-moduledoc """
What an answer of httpc means for a live quote (docs/design-quotes.md,
"One request" and "Refusals and error results"): classify/4 turns the
result httpc delivers for a request into a body to read, a redirect to
follow within the origin asked, or one of the closed set of reasons,
with the `Retry-After` delay a 429 or 503 answer named. word/1 is the
fixed text the screen shows for each reason.

The result is untrusted network input: the classifier is total over
any term, makes no atom, and maps every shape it does not recognise to
`failed`, so it never names a cause it did not see. The shapes it
matches are httpc's and ssl's: `{StatusLine, Headers, Body}` with
lower-case header names, `{error, {failed_connect, [{to_address, _},
{Family, Options, Reason}]}}` (httpc_handler.erl:784-790) and the
`{tls_alert, {Alert, Description}}` an ssl connect fails with
(ssl.erl:604).
""".

-export([classify/4, word/1]).

-export_type([reason/0, class/0]).

-type reason() :: no_net | dns | connect | timeout | certificate | clock_unset
                | tls | {status, 100..999} | redirect | too_big | bad_data | failed.
-type class() :: {body, binary()} | {follow, binary()}
               | {error, reason(), none | pos_integer()}.

-define(MAX_HOPS, 3).
-define(MAX_RETRY_AFTER_MS, 3600000).
%% 2000-01-01T00:00:00Z in seconds of the epoch: a wall clock before it
%% has not been set (docs/design-quotes.md, "The clock").
-define(CLOCK_SET_AFTER, 946684800).
-define(REDIRECTS, [301, 302, 303, 307, 308]).
-define(CERTIFICATE_ALERTS, [bad_certificate, unsupported_certificate,
                             certificate_revoked, certificate_expired,
                             certificate_unknown, unknown_ca]).

-doc """
Classifies httpc's `Result` for a request to `Url` reached after `Hops`
redirects, with the wall clock reading `WallSeconds`, seconds of the
epoch, which tells an expired certificate from an unset clock.
""".
-spec classify(term(), binary(), non_neg_integer(), integer()) -> class().
classify({{_Version, 200, _Phrase}, _Headers, Body}, _Url, _Hops, _Wall)
  when is_binary(Body) ->
    {body, Body};
classify({{_Version, Code, _Phrase}, Headers, _Body}, Url, Hops, _Wall)
  when is_list(Headers) ->
    status(Code, Headers, Url, Hops);
classify({error, Reason}, _Url, _Hops, Wall) ->
    {error, error_reason(Reason, Wall), none};
classify(_Result, _Url, _Hops, _Wall) ->
    {error, failed, none}.

status(200, _Headers, _Url, _Hops) ->
    {error, failed, none};
status(Code, Headers, Url, Hops) when is_integer(Code) ->
    case lists:member(Code, ?REDIRECTS) of
        true -> redirect(header("location", Headers), Url, Hops);
        false when Code >= 100, Code =< 999 ->
            {error, {status, Code}, retry_after(Code, Headers)};
        false -> {error, failed, none}
    end;
status(_Code, _Headers, _Url, _Hops) ->
    {error, failed, none}.

%% The one value of header `Name` as bytes, or none when it is absent,
%% repeated or not a string of bytes.
header(Name, Headers) ->
    case [Value || {Key, Value} <- Headers, Key =:= Name] of
        [Value] when is_list(Value) ->
            case lists:all(fun(C) -> is_integer(C) andalso C >= 0 andalso C =< 255 end, Value) of
                true -> list_to_binary(Value);
                false -> none
            end;
        _Absent -> none
    end.

redirect(Location, Url, Hops) when is_binary(Location), Hops < ?MAX_HOPS ->
    case resolve(Location, Url) of
        {ok, Next} ->
            case same_origin(Next, Url) of
                true -> {follow, Next};
                false -> {error, redirect, none}
            end;
        error ->
            {error, redirect, none}
    end;
redirect(_Location, _Url, _Hops) ->
    {error, redirect, none}.

%% A URI reference is printable ASCII (RFC 3986, section 2), and
%% uri_string raises on some other bytes rather than answering an error,
%% so a location of any other byte is refused before it is parsed.
resolve(Location, Url) ->
    case lists:all(fun(C) -> C > $\s andalso C =< $~ end, binary_to_list(Location)) of
        true ->
            case uri_string:resolve(Location, Url) of
                Next when is_binary(Next) -> {ok, Next};
                _Error -> error
            end;
        false ->
            error
    end.

same_origin(Next, Url) ->
    case {origin(Next), origin(Url)} of
        {{ok, Origin}, {ok, Origin}} -> true;
        _Other -> false
    end.

%% A URL's scheme, host and port, with the host in lower case and https's
%% default port filled in; only https has an origin here.
origin(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = Parsed when is_binary(Host), Host =/= <<>> ->
            case lower(Scheme) of
                <<"https">> -> {ok, {<<"https">>, lower(Host), maps:get(port, Parsed, 443)}};
                _Other -> error
            end;
        _NoOrigin ->
            error
    end.

lower(Text) when is_binary(Text) ->
    << <<(string_lower(C))>> || <<C>> <= Text >>;
lower(_Text) ->
    <<>>.

string_lower(C) when C >= $A, C =< $Z -> C + ($a - $A);
string_lower(C) -> C.

%% The delay a 429 or 503 answer asks for, in milliseconds: a decimal
%% number of seconds of 1 to 10 digits and at least 1, capped at an hour.
%% The HTTP-date form and any other value are none.
retry_after(Code, Headers) when Code =:= 429; Code =:= 503 ->
    case header("retry-after", Headers) of
        none -> none;
        Value -> delay(re:run(Value, "\\A[ \\t]*([0-9]{1,10})[ \\t]*\\z",
                              [{capture, all_but_first, binary}]))
    end;
retry_after(_Code, _Headers) ->
    none.

delay({match, [Digits]}) ->
    case binary_to_integer(Digits) of
        0 -> none;
        Seconds -> min(Seconds * 1000, ?MAX_RETRY_AFTER_MS)
    end;
delay(nomatch) ->
    none.

error_reason({failed_connect, [{to_address, _Address}, {_Family, _Options, Reason}]}, Wall) ->
    connect_reason(Reason, Wall);
error_reason(timeout, _Wall) -> timeout;
error_reason(body_too_big, _Wall) -> too_big;
error_reason({header_too_long, _Max}, _Wall) -> too_big;
error_reason(_Reason, _Wall) -> failed.

connect_reason(eacces, _Wall) -> no_net;
connect_reason(nxdomain, _Wall) -> dns;
connect_reason(Reason, _Wall)
  when Reason =:= econnrefused; Reason =:= ehostunreach;
       Reason =:= enetunreach; Reason =:= timeout ->
    connect;
connect_reason({tls_alert, {certificate_expired, _Description}}, Wall)
  when is_integer(Wall), Wall < ?CLOCK_SET_AFTER ->
    clock_unset;
connect_reason({tls_alert, {Alert, _Description}}, _Wall) ->
    case lists:member(Alert, ?CERTIFICATE_ALERTS) of
        true -> certificate;
        false -> tls
    end;
connect_reason(_Reason, _Wall) ->
    failed.

-doc "The screen's words for a reason (docs/design-quotes.md, \"Refusals and error results\").".
-spec word(reason()) -> binary().
word(no_net) -> <<"no network">>;
word(dns) -> <<"name not found">>;
word(connect) -> <<"cannot connect">>;
word(timeout) -> <<"timed out">>;
word(certificate) -> <<"certificate rejected">>;
word(clock_unset) -> <<"clock not set">>;
word(tls) -> <<"TLS failed">>;
word({status, Code}) -> <<"HTTP ", (integer_to_binary(Code))/binary>>;
word(redirect) -> <<"bad redirect">>;
word(too_big) -> <<"answer too big">>;
word(bad_data) -> <<"bad answer">>;
word(failed) -> <<"failed">>.
