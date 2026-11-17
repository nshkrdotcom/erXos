%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_view).
-moduledoc """
The dashboard's screen as a pure function: tree/1 turns the wall clock's
reading and the last board the quotes source sent into the widget tree erx_ui
draws (docs/design-display.md, "Widget trees"), and the formatters it
uses write every number the screen shows. Nothing here reads a clock or
a process, so the same view always gives the same tree, which the host
test draws and compares with its reference picture.

The screen is a row on the theme's window colour. On the left, centred,
the clock: the model's `dial`, the picture erx_dashboard_clock:png/1
draws of the hour and minute, which the dashboard draws once a minute,
with the date under it and the time, `HH:MM UTC`, under that. On the
right, the quotes panel: the title `Markets` over the board's credit,
then one card, a `section`, per quote: its name over its status line,
or its symbol when the source gives no status, beside its price over its
change, each `--` when the quote has none, and under them a graph of the
quote's recent prices with the day's opening price marked across it. A
card's key is its quote's symbol, so a board that reorders its quotes
moves cards instead of rewriting their text. Before the first board the
panel says it is waiting.

A board is the source's credit, the line under the panel's title that
says where the numbers come from, and its quotes in the order the
screen lists them. A quote's price is in its own currency and its
change a percent change, each a number or `none`, shown as `--`; its
`samples` are its recent prices, oldest first, in the same currency. Its
`status`, when given, is the line shown under its name in place of its
symbol. erx_quotes builds every board from its table, a reviewed
constant (erx_quotes_table) whose `decimals` lie within 0 to 8, whose
symbols are unique and whose texts are ASCII within the widget format's
bounds; the view checks nothing again.
""".

-export([tree/1, clock/1, date/1, minute/1, price/2, change/1]).

-export_type([model/0, board/0, quote/0]).

-type quote() :: #{symbol := binary(),
                   name := binary(),
                   price := none | number(),
                   change := none | number(),
                   decimals := 0..8,
                   samples := [number()],
                   status => binary()}.
-type board() :: #{credit := binary(), quotes := [quote()]}.
-type model() :: #{time := calendar:datetime(),
                   dial := binary(),
                   board := none | board()}.

%% The graph's range: a card's prices are scaled onto it, so no price,
%% however large, leaves the widget format's integers.
-define(GRAPH_SCALE, 1000).

-define(MONTHS, {<<"January">>, <<"February">>, <<"March">>, <<"April">>,
                 <<"May">>, <<"June">>, <<"July">>, <<"August">>,
                 <<"September">>, <<"October">>, <<"November">>,
                 <<"December">>}).
-define(WEEKDAYS, {<<"Monday">>, <<"Tuesday">>, <<"Wednesday">>,
                   <<"Thursday">>, <<"Friday">>, <<"Saturday">>,
                   <<"Sunday">>}).

-doc "The widget tree of `Model`.".
-spec tree(model()) -> erx_ui_model:tree().
tree(#{time := Time, board := Board, dial := Dial}) ->
    Size = erx_dashboard_clock:size(),
    {row, #{pad => 56},
     [{column, #{weight => 1},
       [{spacer, #{weight => 1}, []},
        centred({image, #{width => Size, height => Size, image => Dial,
                          image_type => png, alt => clock(Time)}, []}),
        gap(20),
        centred({label, #{height => 28, role => title, text => date(Time)}, []}),
        gap(4),
        centred({label, #{height => 16, role => caption, text => <<(clock(Time))/binary, " UTC">>}, []}),
        {spacer, #{weight => 1}, []}]},
      {spacer, #{width => 48}, []},
      {column, #{width => 440}, [gap(16) | panel(Board)]}]}.

panel(none) ->
    [panel_header(<<"Waiting for quotes">>)];
panel(#{credit := Credit, quotes := Quotes}) ->
    [panel_header(Credit) | lists:append([[gap(20), card(Quote)] || Quote <- Quotes])].

panel_header(Note) ->
    {column, #{height => 52},
     [{label, #{height => 28, role => title, text => <<"Markets">>}, []},
      {label, #{height => 16, role => caption, text => Note}, []}]}.

gap(Height) ->
    {spacer, #{height => Height}, []}.

%% A node in the middle of a row of its own, and one at its end: the
%% spacers take the room the node leaves.
centred(Node) ->
    {row, #{}, [{spacer, #{weight => 1}, []}, Node, {spacer, #{weight => 1}, []}]}.

flush_right(Node) ->
    {row, #{}, [{spacer, #{weight => 1}, []}, Node]}.

%% A quote's card: its name over its status line, or its symbol when the
%% source gives no status, beside its price over its change, each `--`
%% when the quote has none; under them the graph of its recent prices.
card(#{symbol := Symbol, name := Name, price := Price, change := Change,
       decimals := Decimals} = Quote) ->
    {column, #{key => Symbol, area => section, pad => 20, height => 180},
     [{row, #{height => 48},
       [{column, #{weight => 1},
         [{label, #{height => 28, role => title, text => Name}, []},
          {label, #{height => 20, role => caption,
                    text => maps:get(status, Quote, Symbol)}, []}]},
        {column, #{width => 140},
         [flush_right({label, #{height => 28, role => title,
                                text => or_none(Price, fun(P) -> price(P, Decimals) end)}, []}),
          flush_right({label, #{height => 20, role => numeric,
                                text => or_none(Change, fun change/1)}, []})]}]},
      gap(16),
      graph(Quote)]}.

%% A quote's recent prices, scaled onto 0 to ?GRAPH_SCALE between the
%% lowest and highest of them, so the line uses the graph's height. The
%% day's opening price, when the quote has a change to derive it from, is
%% marked across them if it lies within their range, and alone in the
%% middle before the first price.
graph(#{samples := Samples} = Quote) ->
    Props = case {Samples, open(Quote)} of
                {[], none} -> #{samples => []};
                {[], Open} -> scaled([], Open, Open, Open);
                {_, Open} -> scaled(Samples, Open, lists:min(Samples), lists:max(Samples))
            end,
    {graph, Props#{height => 76, min => 0, max => ?GRAPH_SCALE}, []}.

%% The price at the start of the change: price / (1 + change / 100).
open(#{price := Price, change := Change}) when is_number(Price), is_number(Change) ->
    Price / (1 + Change / 100);
open(#{}) ->
    none.

%% Prices between Low and High onto the graph's range, with a tenth of
%% its height kept free above and below; a flat series lies in the middle.
scaled(Samples, Open, Low, High) ->
    Span = High - Low,
    Scale = fun(_Value) when Span == 0 -> ?GRAPH_SCALE div 2;
               (Value) -> round(?GRAPH_SCALE * (0.1 + 0.8 * (Value - Low) / Span))
            end,
    Mark = case Open of
               _ when Open =:= none; Open < Low; Open > High -> #{};
               _ -> #{mark => Scale(Open)}
           end,
    Mark#{samples => [Scale(Sample) || Sample <- Samples]}.

or_none(none, _Format) -> <<"--">>;
or_none(Number, Format) -> Format(Number).

-doc "The time of day, `HH:MM`, of a wall-clock reading.".
-spec clock(calendar:datetime()) -> binary().
clock({_Date, {Hour, Minute, _Second}}) ->
    iolist_to_binary(io_lib:format("~2..0B:~2..0B", [Hour, Minute])).

-doc """
The minute of a wall-clock reading, as `2026-11-15 09:41`: the screen
`tree/1` draws for a reading depends on nothing of it finer, so the
dashboard names the screen it shows by this.
""".
-spec minute(calendar:datetime()) -> binary().
minute({{Year, Month, Day}, {Hour, Minute, _Second}}) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B", [Year, Month, Day, Hour, Minute])).

-doc "The date of a wall-clock reading, as `Sunday, 15 November 2026`.".
-spec date(calendar:datetime()) -> binary().
date({{Year, Month, Day} = Date, _Time}) ->
    Weekday = element(calendar:day_of_the_week(Date), ?WEEKDAYS),
    iolist_to_binary([Weekday, ", ", integer_to_binary(Day), " ",
                      element(Month, ?MONTHS), " ", integer_to_binary(Year)]).

-doc """
`Price` rounded to `Decimals` digits after the point, its whole part in
groups of three digits: `price(64000.0, 2)` is `<<"64,000.00">>`.
""".
-spec price(number(), 0..8) -> binary().
price(Price, Decimals) ->
    Scaled = round(Price * pow10(Decimals)),
    Whole = abs(Scaled) div pow10(Decimals),
    Fraction = abs(Scaled) rem pow10(Decimals),
    iolist_to_binary([minus(Scaled), grouped(Whole),
                      fraction(Fraction, Decimals)]).

-doc """
A percent change rounded to two digits after the point, with its sign:
`<<"+1.25%">>`, `<<"-0.50%">>`, and `<<"0.00%">>` for a change that
rounds to nothing.
""".
-spec change(number()) -> binary().
change(Percent) ->
    Hundredths = round(Percent * 100),
    Sign = if Hundredths > 0 -> "+"; true -> minus(Hundredths) end,
    iolist_to_binary([Sign, grouped(abs(Hundredths) div 100),
                      fraction(abs(Hundredths) rem 100, 2), "%"]).

minus(N) when N < 0 -> "-";
minus(_N) -> "".

grouped(N) when N < 1000 -> integer_to_list(N);
grouped(N) -> [grouped(N div 1000), io_lib:format(",~3..0B", [N rem 1000])].

fraction(_Fraction, 0) -> "";
fraction(Fraction, Decimals) ->
    io_lib:format(".~*..0B", [Decimals, Fraction]).

pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).
