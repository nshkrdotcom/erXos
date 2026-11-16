%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_config).
-moduledoc """
The live quotes' source table (docs/design-quotes.md, "The source
table"): read/1 reads `quotes.config` with file:consult/1 and
validate/1 checks the terms whole, so the rest of the live source works
only on a table every bound of the design holds for.

The file is the app's own, authenticated with its package, but it is
checked as untrusted input all the same: a term of an unknown shape, an
unknown or missing field, or a value past its bound refuses the whole
table with `{refused, Row, Field, Why}`, where Row is `{quote, Name}`,
`{source, Name}`, `{term, Index}` for a term that is no row, or `table`
for a rule over the whole table. Validation turns each `period` into
milliseconds, the unit of every time the core holds.
""".

-include_lib("kernel/include/file.hrl").

-export([read/1, validate/1]).

-export_type([table/0, quote/0, source/0, path/0, refusal/0]).

-type path() :: [binary() | non_neg_integer(), ...].
-type quote() :: #{label := binary(), decimals := 0..8,
                   period := pos_integer(), sources := [atom(), ...]}.
-type source() :: #{url := binary(), format := json | {csv, 1..16},
                    price := none | path(),
                    change := none | {from, path()} | {percent, path()},
                    credit := binary(), note := binary()}.
-type table() :: #{quotes := [{atom(), quote()}, ...],
                   sources := #{atom() => source()}}.
-type refusal() :: {refused, term(), atom(), atom()}.

-define(MAX_FILE_BYTES, 65536).
-define(MAX_QUOTES, 8).
-define(MAX_SOURCES, 16).
-define(MAX_QUOTE_SOURCES, 4).
-define(MAX_PATH, 8).
-define(MAX_URL_BYTES, 512).

-doc """
Reads and validates the table in the file `Path`. A file over 64 KiB,
one file:consult/1 cannot parse, and a table validate/1 refuses are
each an error with the reason.
""".
-spec read(file:filename_all()) -> {ok, table()} | {error, term()}.
read(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{size = Size}} when Size > ?MAX_FILE_BYTES -> {error, too_big};
        {ok, _Info} -> consulted(file:consult(Path));
        {error, Reason} -> {error, Reason}
    end.

consulted({ok, Terms}) -> validate(Terms);
consulted({error, Reason}) -> {error, Reason}.

-doc "Checks the terms of a table whole, answering the table or the first refusal.".
-spec validate(term()) -> {ok, table()} | {error, refusal()}.
validate(Terms) ->
    try
        {ok, table(Terms)}
    catch
        throw:{refused, _Row, _Field, _Why} = Refusal -> {error, Refusal}
    end.

refuse(Row, Field, Why) ->
    throw({refused, Row, Field, Why}).

table(Terms) when is_list(Terms) ->
    Rows = lists:zipwith(fun row/2, lists:seq(1, length(Terms)), Terms),
    Quotes = [{Name, Map} || {quote, Name, Map} <- Rows],
    Sources = [{Name, Map} || {source, Name, Map} <- Rows],
    unique([Name || {Name, _} <- Quotes], quote),
    unique([Name || {Name, _} <- Sources], source),
    bounded(Quotes, 1, ?MAX_QUOTES, quotes),
    bounded(Sources, 1, ?MAX_SOURCES, sources),
    SourceMap = maps:from_list([{Name, source(Name, Map)} || {Name, Map} <- Sources]),
    QuoteList = [{Name, quote(Name, Map, SourceMap)} || {Name, Map} <- Quotes],
    Used = lists:usort(lists:append([Names || {_, #{sources := Names}} <- QuoteList])),
    case maps:keys(SourceMap) -- Used of
        [] -> #{quotes => QuoteList, sources => SourceMap};
        [Unused | _] -> refuse({source, Unused}, sources, unused)
    end;
table(_Terms) ->
    refuse(table, terms, not_a_list).

row(Index, {Kind, Name, Map} = Row)
  when (Kind =:= quote orelse Kind =:= source), is_atom(Name), is_map(Map) ->
    %% A name is a row's key on the screen, within the widget format's bound.
    _ = text({term, Index}, name, atom_to_binary(Name), 1, 32),
    Row;
row(Index, _Term) ->
    refuse({term, Index}, row, unknown_shape).

unique(Names, Kind) ->
    case Names -- lists:usort(Names) of
        [] -> ok;
        [Twice | _] -> refuse({Kind, Twice}, name, duplicate)
    end.

bounded(List, Min, Max, Field) ->
    case length(List) of
        N when N >= Min, N =< Max -> ok;
        _ -> refuse(table, Field, count)
    end.

quote(Name, Map, Sources) ->
    Row = {quote, Name},
    fields(Row, Map, [label, decimals, period, sources], []),
    #{label => text(Row, label, maps:get(label, Map), 1, 32),
      decimals => integer(Row, decimals, maps:get(decimals, Map), 0, 8),
      period => 1000 * integer(Row, period, maps:get(period, Map), 5, 86400),
      sources => quote_sources(Row, maps:get(sources, Map), Sources)}.

quote_sources(Row, Names, Sources) when is_list(Names) ->
    bounded_field(Row, sources, list_length(Row, sources, Names), 1, ?MAX_QUOTE_SOURCES),
    [case is_map_key(Name, Sources) of
         true -> Name;
         false -> refuse(Row, sources, unknown_source)
     end || Name <- Names],
    case length(lists:usort(Names)) =:= length(Names) of
        true -> Names;
        false -> refuse(Row, sources, duplicate)
    end;
quote_sources(Row, _Names, _Sources) ->
    refuse(Row, sources, not_a_list).

source(Name, Map) ->
    Row = {source, Name},
    Format = format(Row, maps:get(format, Map, missing)),
    Required = case Format of
                   json -> [url, format, price, change, credit];
                   {csv, _} -> [url, format, change, credit]
               end,
    fields(Row, Map, Required, [note]),
    #{url => url(Row, maps:get(url, Map)),
      format => Format,
      price => price(Row, Format, maps:get(price, Map, none)),
      change => change(Row, Format, maps:get(change, Map)),
      credit => text(Row, credit, maps:get(credit, Map), 1, 32),
      note => text(Row, note, maps:get(note, Map, <<>>), 0, 48)}.

%% Every required field present, and no field but the required and the optional.
fields(Row, Map, Required, Optional) ->
    case Required -- maps:keys(Map) of
        [] -> ok;
        [Missing | _] -> refuse(Row, Missing, missing)
    end,
    case maps:keys(Map) -- (Required ++ Optional) of
        [] -> ok;
        [Unknown | _] when is_atom(Unknown) -> refuse(Row, Unknown, unknown_field);
        [_Unknown | _] -> refuse(Row, field, unknown_field)
    end.

format(_Row, json) -> json;
format(Row, {csv, Column}) -> {csv, integer(Row, format, Column, 1, 16)};
format(Row, missing) -> refuse(Row, format, missing);
format(Row, _Format) -> refuse(Row, format, unknown_format).

price(Row, json, Path) -> path(Row, price, Path);
price(_Row, {csv, _}, none) -> none.

change(_Row, _Format, none) -> none;
change(Row, json, {Rule, Path}) when Rule =:= from; Rule =:= percent ->
    {Rule, path(Row, change, Path)};
change(Row, _Format, _Change) -> refuse(Row, change, unknown_rule).

path(Row, Field, Path) when is_list(Path) ->
    bounded_field(Row, Field, list_length(Row, Field, Path), 1, ?MAX_PATH),
    case lists:all(fun step/1, Path) of
        true -> Path;
        false -> refuse(Row, Field, bad_step)
    end;
path(Row, Field, _Path) ->
    refuse(Row, Field, not_a_path).

step(Key) when is_binary(Key) -> true;
step(Index) when is_integer(Index), Index >= 0 -> true;
step(_Step) -> false.

url(Row, Url) when is_binary(Url), byte_size(Url) =< ?MAX_URL_BYTES ->
    %% uri_string raises on some bytes outside printable ASCII, which no URL holds.
    _ = text(Row, url, Url, 1, ?MAX_URL_BYTES),
    case uri_string:parse(Url) of
        #{scheme := <<"https">>, host := Host} when byte_size(Host) > 0 -> Url;
        #{scheme := _} -> refuse(Row, url, not_https);
        _NoScheme -> refuse(Row, url, unparsable)
    end;
url(Row, _Url) ->
    refuse(Row, url, bound).

text(Row, Field, Text, Min, Max) when is_binary(Text) ->
    bounded_field(Row, Field, byte_size(Text), Min, Max),
    case lists:all(fun(C) -> C >= $\s andalso C =< $~ end, binary_to_list(Text)) of
        true -> Text;
        false -> refuse(Row, Field, not_printable)
    end;
text(Row, Field, _Text, _Min, _Max) ->
    refuse(Row, Field, not_text).

%% The length of a proper list; an improper one is refused.
list_length(Row, Field, List) ->
    try length(List) catch error:badarg -> refuse(Row, Field, not_a_list) end.

integer(_Row, _Field, N, Min, Max) when
 is_integer(N), N >= Min, N =< Max -> N;
integer(Row, Field, _N, _Min, _Max) -> refuse(Row, Field, bound).

bounded_field(_Row, _Field, N, Min, Max) when N >= Min, N =< Max -> ok;
bounded_field(Row, Field, _N, _Min, _Max) -> refuse(Row, Field, bound).
