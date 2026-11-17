%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_extract).
-moduledoc """
The one reader of a live quote's response bytes (docs/design-quotes.md,
"Reading a body"): value/2 takes a source row of the table and the body
httpc delivered and answers the price and change it carries, or
`bad_data`.

The body is untrusted network input of at most 64 KiB, the bound httpc
enforced, and is read by total functions: through json:decode/1, which
keeps its own stack and makes no atom, then walked along the row's
path. A price is a JSON number or a decimal string of the grammar
`-?[0-9]{1,15}(\.[0-9]{1,12})?`, at least 10^-12 and below 10^15; a
change's reference value is checked the same way, and the percentage
computed from it must lie in [-100, 1000]. Every check throws
`bad_data`, which value/2 catches once.
""".

-export([value/2]).

-define(MAX_BODY, 65536).
-define(MAX_DECIMAL, 32).
-define(MIN_PRICE, 1.0e-12).
%% An integer, so a JSON integer of any size compares with it exactly.
-define(MAX_PRICE, 1000000000000000).
-define(DECIMAL, "\\A-?[0-9]{1,15}(?:\\.[0-9]{1,12})?\\z").

-doc "The price and change `Body` carries for `Source`, or `{error, bad_data}`.".
-spec value(erx_quotes_table:source(), binary()) ->
          {ok, float(), none | float()} | {error, bad_data}.
value(Source, Body) when is_binary(Body), byte_size(Body) =< ?MAX_BODY ->
    try read(Source, Body) of
        {Price, Change} -> {ok, Price, Change}
    catch
        throw:bad_data -> {error, bad_data}
    end;
value(_Source, _Body) ->
    {error, bad_data}.

read(#{format := json, price := PricePath, change := Rule}, Body) ->
    Answer = decode(Body),
    Price = price(walk(Answer, PricePath)),
    {Price, change(Rule, Answer, Price)}.

decode(Body) ->
    try
        json:decode(Body)
    catch
        error:_Malformed -> throw(bad_data)
    end.

%% The value at `Path`: a binary step needs an object holding that key, an
%% integer step a list long enough.
walk(Value, []) ->
    Value;
walk(Object, [Key | Path]) when is_map(Object), is_binary(Key) ->
    case Object of
        #{Key := Value} -> walk(Value, Path);
        #{} -> throw(bad_data)
    end;
walk(List, [Index | Path]) when is_list(List), is_integer(Index), Index < length(List) ->
    walk(lists:nth(Index + 1, List), Path);
walk(_Value, _Path) ->
    throw(bad_data).

change(none, _Answer, _Price) ->
    none;
change({from, Path}, Answer, Price) ->
    Reference = price(walk(Answer, Path)),
    percent((Price - Reference) / Reference * 100).

%% A change lies in [-100, 1000] percent; both prices
%% lie within [10^-12, 10^15), so the computation cannot overflow.
percent(Percent) when Percent >= -100, Percent =< 1000 -> float(Percent);
percent(_Percent) -> throw(bad_data).

%% A price, a JSON number as a decimal string, lies in [10^-12, 10^15):
%% the range of the decimal grammar.
price(Value) ->
    case number(Value) of
        Price when Price >= ?MIN_PRICE, Price < ?MAX_PRICE -> float(Price);
        _Outside -> throw(bad_data)
    end.

number(Number) when is_number(Number) ->
    Number;
number(Text) when is_binary(Text), byte_size(Text) =< ?MAX_DECIMAL ->
    case decimal(Text) of
        true -> decimal_value(Text);
        false -> throw(bad_data)
    end;
number(_Value) ->
    throw(bad_data).

decimal(Text) ->
    re:run(Text, ?DECIMAL, [{capture, none}]) =:= match.

%% A text the decimal grammar accepted, as a number.
decimal_value(Text) ->
    case binary:match(Text, <<".">>) of
        nomatch -> binary_to_integer(Text);
        _Point -> binary_to_float(Text)
    end.

