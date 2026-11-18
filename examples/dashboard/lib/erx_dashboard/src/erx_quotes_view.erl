%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_view).
-moduledoc """
What the dashboard's quotes panel shows of the live quotes, as a pure
function (examples/dashboard/README.md, "What it shows"): board/2 turns
the core's state and the current monotonic time into the board the
dashboard draws (erx_dashboard_view), one quote per row of the table,
in its order, under a credit naming every source the table asks
(credits/2). Whether a quote's value is shown as current is state/3
alone: a value at most three periods old is current, and an older one
is stale and shown with its age. Either way, the reason the quote's last
round failed follows its line; a quote without a value shows `--` and
why. A card's graph is the quote's
series of 15 min closes once a history arrived, and its live samples
before; the status line says which, `24 h chart` or `live chart`.

Every text is the table's, a fixed word, the middle dot or a number
formatted here; no byte of a response reaches the board.
""".

-export([board/2, lines/2, age/1]).

%% What separates a status line's fields: U+00B7, the middle dot.
-define(DOT, <<" \x{B7} "/utf8>>).

-doc "The board of the core's `State` at monotonic time `Now`.".
-spec board(erx_quotes_core:state(), integer()) -> erx_dashboard_view:board().
board(#{table := #{quotes := Rows, sources := Sources}, quotes := Quotes}, Now) ->
    #{credit => credits(Rows, Sources),
      quotes => [quote(Name, Row, maps:get(Name, Quotes), Sources, Now)
                 || {Name, Row} <- Rows]}.

%% The board's credit: every source's credit the table's quotes may ask,
%% each once, in the order they ask them. The panel's header shows it, so
%% a status line does not repeat it.
credits(Rows, Sources) ->
    Credits = [maps:get(credit, maps:get(Source, Sources))
               || {_Name, #{sources := Names}} <- Rows, Source <- Names],
    iolist_to_binary(lists:join(<<", ">>, lists:uniq(Credits))).

quote(Name, #{label := Label, decimals := Decimals} = Row, Quote, Sources, Now) ->
    {Price, Change} = case Quote of
                          #{value := {P, C, _Source, _At}} -> {P, C};
                          #{value := none} -> {none, none}
                      end,
    #{symbol => atom_to_binary(Name), name => Label, price => Price, change => Change,
      samples => points(Quote),
      decimals => Decimals, status => status(Quote, Row, Sources, Now)}.

%% What a card's graph draws: the closes of the quote's series once a
%% history arrived, else its live samples.
points(#{series := none, samples := Samples}) -> Samples;
points(#{series := Series}) -> [Close || {_Start, Close} <- Series].

%% A quote's status line: `waiting`, `no data: REASON`, `[NOTE . ]RANGE
%% chart` while its value is fresh and `stale, AGE . [NOTE . ]RANGE chart`
%% once stale, each of the last two followed by `: REASON` when the
%% quote's last round failed; `.` stands for ?DOT. NOTE is the note of
%% the source that gave the value and RANGE what the graph spans
%% (range/1). `Sources` are the table's source rows.
-spec status(erx_quotes_core:quote(), erx_quotes_table:quote(),
             #{atom() => erx_quotes_table:source()}, integer()) -> binary().
status(#{value := Value, failure := Failure} = Quote, Row, Sources, Now) ->
    case {state(Quote, Row, Now), Value, Failure} of
        {waiting, none, none} ->
            <<"waiting">>;
        {no_data, none, {Reason, _At}} ->
            <<"no data: ", (erx_quotes_http:word(Reason))/binary>>;
        {Shown, {_Price, _Change, Source, FetchedAt}, _} ->
            Stale = case Shown of
                        fresh -> [];
                        stale -> [<<"stale, ", (age(Now - FetchedAt))/binary>>]
                    end,
            Note = case maps:get(Source, Sources) of
                       #{note := <<>>} -> [];
                       #{note := Text} -> [Text]
                   end,
            Fields = Stale ++ Note ++ [<<(range(Quote))/binary, " chart">>],
            iolist_to_binary([lists:join(?DOT, Fields) | reason(Failure)])
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

%% What the graph spans: a day of history, erx_quotes_core:buckets/0 of
%% erx_quotes_core:bucket/0, or the live samples alone.
range(#{series := none}) -> <<"live">>;
range(#{}) -> <<"24 h">>.

reason(none) -> [];
reason({Reason, _At}) -> [?DOT, erx_quotes_http:word(Reason)].

-doc """
The log's view of the board: per quote of the table, in its order, the
quote's name and one line naming it, its state (`waiting`, `no_data`,
`fresh` or `stale`, by the rule of state/3), the price as the screen shows
it (erx_dashboard_view:price/2) or `--`, and the reason its last round failed, or else the
source that gave its value (`none` before any). Ages are left out, so a
line changes only when the quote's state, price, source or reason does;
erx_quotes logs each change (examples/dashboard/README.md, "The QEMU
cell").
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
