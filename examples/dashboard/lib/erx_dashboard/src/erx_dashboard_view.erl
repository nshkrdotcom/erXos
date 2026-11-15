%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_view).
-moduledoc """
The dashboard's screen as a pure function: tree/1 turns the wall clock's
reading and the last board a source sent into the widget tree erx_ui
draws (docs/design-display.md, "Widget trees"), and the formatters it
uses write every number the screen shows. Nothing here reads a clock or
a process, so the same view always gives the same tree, which the host
test draws and compares with its reference picture.

The screen is a column: at the top the time, `HH:MM` in the `display`
role, with the date under it and the time zone, `UTC`, beside it; below,
the quotes panel, a `section` with the title `Markets`, the board's
credit and one row per quote: its name over its symbol, its price and
its change. A
row's key is its quote's symbol, so a board that reorders its quotes
moves rows instead of rewriting their text. Before the first board the
panel says it is waiting.
""".

-export([tree/1, clock/1, date/1, price/2, change/1]).

-export_type([model/0]).

-type model() :: #{time := calendar:datetime(),
                   board := none | erx_dashboard_source:board()}.

-define(MONTHS, {<<"January">>, <<"February">>, <<"March">>, <<"April">>,
                 <<"May">>, <<"June">>, <<"July">>, <<"August">>,
                 <<"September">>, <<"October">>, <<"November">>,
                 <<"December">>}).
-define(WEEKDAYS, {<<"Monday">>, <<"Tuesday">>, <<"Wednesday">>,
                   <<"Thursday">>, <<"Friday">>, <<"Saturday">>,
                   <<"Sunday">>}).

-doc "The widget tree of `Model`.".
-spec tree(model()) -> erx_ui_model:tree().
tree(#{time := Time, board := Board}) ->
    {column, #{pad => 32},
     [{row, #{height => 128},
       [{column, #{weight => 1},
         [{label, #{height => 72, role => display, text => clock(Time)}, []},
          {label, #{height => 32, role => title, text => date(Time)}, []}]},
        {label, #{width => 64, height => 32, role => caption,
                  text => <<"UTC">>}, []}]},
      {column, #{pad => 24, area => section}, panel(Board)}]}.

panel(none) ->
    [panel_header(<<"Waiting for quotes">>)];
panel(#{credit := Credit, quotes := Quotes}) ->
    [panel_header(Credit) | [quote_row(Quote) || Quote <- Quotes]].

panel_header(Note) ->
    {row, #{height => 48},
     [{label, #{weight => 2, role => title, text => <<"Markets">>}, []},
      {label, #{weight => 2, role => caption, text => Note}, []}]}.

quote_row(#{symbol := Symbol, name := Name, price := Price, change := Change,
            decimals := Decimals}) ->
    {row, #{key => Symbol, height => 64},
     [{column, #{weight => 2},
       [{label, #{height => 24, role => heading, text => Name}, []},
        {label, #{height => 16, role => caption, text => Symbol}, []}]},
      {label, #{weight => 1, role => title, text => price(Price, Decimals)}, []},
      {label, #{weight => 1, role => numeric, text => change(Change)}, []}]}.

-doc "The time of day, `HH:MM`, of a wall-clock reading.".
-spec clock(calendar:datetime()) -> binary().
clock({_Date, {Hour, Minute, _Second}}) ->
    iolist_to_binary(io_lib:format("~2..0B:~2..0B", [Hour, Minute])).

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
