%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_view).
-moduledoc """
What the dashboard's quotes panel shows of the live quotes, as a pure
function (docs/design-quotes.md, "What the screen shows"): board/2 turns
the core's state and the current monotonic time into the board the
dashboard draws (erx_dashboard_view), one quote per row of the table,
in its order. The rule of Q-R1 and Q-R2 is state/3 alone: a quote
shows the last value it received, the source that gave it and its age,
stale once older than three periods, with the reason its last round
failed beside it; a quote without a value shows `--` and why.

Every text is the table's, a fixed word or a number formatted here; no
byte of a response reaches the board.
""".

-export([board/2, lines/2, age/1]).

-define(CREDIT, <<"Live quotes">>).

-doc "The board of the core's `State` at monotonic time `Now`.".
-spec board(erx_quotes_core:state(), integer()) -> erx_dashboard_view:board().
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
%% AGE` while its value is fresh and `stale, AGE - CREDIT[, NOTE]` once
%% stale, each of the last two followed by `: REASON` when the quote's last
%% round failed. `Sources` are the table's source rows.
-spec status(erx_quotes_core:quote(), erx_quotes_table:quote(),
             #{atom() => erx_quotes_table:source()}, integer()) -> binary().
status(#{value := Value, failure := Failure} = Quote, Row, Sources, Now) ->
    case {state(Quote, Row, Now), Value, Failure} of
        {waiting, none, none} ->
            <<"waiting">>;
        {no_data, none, {Reason, _At}} ->
            <<"no data: ", (erx_quotes_http:word(Reason))/binary>>;
        {Shown, {_Price, _Change, Source, FetchedAt}, _} ->
            Age = age(Now - FetchedAt),
            Credit = credit(maps:get(Source, Sources)),
            Line = case Shown of
                       fresh -> [Credit, " - ", Age];
                       stale -> ["stale, ", Age, " - ", Credit]
                   end,
            iolist_to_binary([Line | reason(Failure)])
    end.

%% The one rule of Q-R1 and Q-R2: a value is stale once older than three
%% of its quote's periods, and a quote without one is waiting until its
%% first round fails.
-spec state(erx_quotes_core:quote(), erx_quotes_table:quote(), integer()) ->
          waiting | no_data | fresh | stale.
state(#{value := none, failure := none}, _Row, _Now) -> waiting;
state(#{value := none}, _Row, _Now) -> no_data;
state(#{value := {_, _, _, FetchedAt}}, #{period := Period}, Now)
  when Now - FetchedAt > 3 * Period -> stale;
state(#{value := {_, _, _, _}}, _Row, _Now) -> fresh.

credit(#{credit := Credit, note := <<>>}) -> Credit;
credit(#{credit := Credit, note := Note}) -> [Credit, ", ", Note].

reason(none) -> [];
reason({Reason, _At}) -> [": ", erx_quotes_http:word(Reason)].

-doc """
The log's view of the board: per quote of the table, in its order, the
quote's name and one line naming it, its state (`waiting`, `no_data`,
`fresh` or `stale`, by the rule of state/3), the price as the screen shows
it (erx_dashboard_view:price/2) or `--`, and the reason its last round failed, or else the
source that gave its value (`none` before any). Ages are left out, so a
line changes only when the quote's state, price, source or reason does;
erx_quotes logs each change (docs/design-quotes.md, "Verification and
testing").
""".
-spec lines(erx_quotes_core:state(), integer()) -> [{atom(), binary()}].
lines(#{table := #{quotes := Rows}, quotes := Quotes}, Now) ->
    [{Name, line(Name, Row, maps:get(Name, Quotes), Now)} || {Name, Row} <- Rows].

line(Name, #{decimals := Decimals} = Row, #{value := Value, failure := Failure} = Quote, Now) ->
    {Price, Source} = case Value of
                          none -> {<<"--">>, none};
                          {P, _Change, S, _At} -> {erx_dashboard_view:price(P, Decimals), S}
                      end,
    Why = case Failure of
              none -> Source;
              {Reason, _FailedAt} -> Reason
          end,
    iolist_to_binary(io_lib:format("~ts ~ts ~ts ~0p",
                                   [Name, state(Quote, Row, Now), Price, Why])).

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
