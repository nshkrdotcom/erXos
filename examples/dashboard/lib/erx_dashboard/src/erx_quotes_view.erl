%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_view).
-moduledoc """
What the dashboard's quotes panel shows of the live quotes, as a pure
function (docs/design-quotes.md, "What the screen shows"): board/2 turns
the core's state and the current monotonic time into the board the
dashboard draws (erx_dashboard_source), one quote per row of the table,
in its order. The rules of Q-R1 and Q-R2 are status/4 alone: a quote
shows the last value it received, the source that gave it and its age,
stale once older than three periods, with the reason its last round
failed beside it; a quote without a value shows `--` and why.

Every text is the table's, a fixed word or a number formatted here; no
byte of a response reaches the board.
""".

-export([board/2, age/1]).

-define(CREDIT, <<"Live quotes">>).

-doc "The board of the core's `State` at monotonic time `Now`.".
-spec board(erx_quotes_core:state(), integer()) -> erx_dashboard_source:board().
board(#{table := #{quotes := Rows, sources := Sources}, quotes := Quotes}, Now) ->
    #{credit => ?CREDIT,
      quotes => [quote(Name, Row, maps:get(Name, Quotes), Sources, Now)
                 || {Name, Row} <- Rows]}.

quote(Name, #{label := Label, decimals := Decimals} = Row, Quote, Sources, Now) ->
    {Price, Change} = case Quote of
                          #{value := {P, C, _Source, _At}} -> {P, C};
                          #{value := none} -> {none, none}
                      end,
    #{symbol => atom_to_binary(Name), name => Label, price => Price, change => Change,
      decimals => Decimals, status => status(Quote, Row, Sources, Now)}.

%% A quote's status line: `waiting`, `no data: REASON`, `CREDIT[, NOTE] -
%% AGE` while its value is at most three periods old, and `stale, AGE -
%% CREDIT[, NOTE]` beyond, each of the last two followed by `: REASON` when
%% the quote's last round failed. `Sources` are the table's source rows.
-spec status(erx_quotes_core:quote(), erx_quotes_config:quote(),
             #{atom() => erx_quotes_config:source()}, integer()) -> binary().
status(#{value := none, failure := none}, _Row, _Sources, _Now) ->
    <<"waiting">>;
status(#{value := none, failure := {Reason, _At}}, _Row, _Sources, _Now) ->
    <<"no data: ", (erx_quotes_http:word(Reason))/binary>>;
status(#{value := {_Price, _Change, Source, FetchedAt}, failure := Failure},
       #{period := Period}, Sources, Now) ->
    Age = Now - FetchedAt,
    Credit = credit(maps:get(Source, Sources)),
    Line = case Age > 3 * Period of
               false -> [Credit, " - ", age(Age)];
               true -> ["stale, ", age(Age), " - ", Credit]
           end,
    iolist_to_binary([Line | reason(Failure)]).

credit(#{credit := Credit, note := <<>>}) -> Credit;
credit(#{credit := Credit, note := Note}) -> [Credit, ", ", Note].

reason(none) -> [];
reason({Reason, _At}) -> [": ", erx_quotes_http:word(Reason)].

-doc """
An age in milliseconds as the screen shows it, rounded down: `N s` below
two minutes, `N min` below two hours, `N h` below two days, `N d` beyond.
""".
-spec age(integer()) -> binary().
age(Ms) ->
    Seconds = max(Ms, 0) div 1000,
    {N, Unit} = if Seconds < 120 -> {Seconds, <<" s">>};
                   Seconds < 7200 -> {Seconds div 60, <<" min">>};
                   Seconds < 172800 -> {Seconds div 3600, <<" h">>};
                   true -> {Seconds div 86400, <<" d">>}
                end,
    <<(integer_to_binary(N))/binary, Unit/binary>>.
