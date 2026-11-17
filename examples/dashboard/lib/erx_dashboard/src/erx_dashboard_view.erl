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

The screen is a row over the model's `ground`, the picture
erx_dashboard_pictures:ground/1 draws once. On the left, centred, the
clock: the model's `dial`, the picture erx_dashboard_clock:png/2 draws
of the hour and minute, which the dashboard draws once a minute, with
the date under it in the `headline` role and the time, `HH:MM UTC`,
under that. On the right, the quotes panel: the title `Markets` with the
board's credit flush right, then one block per quote, split by
hairlines rather than boxed: its name over its status line, or its
symbol when the source gives no status, beside its price in the `figure`
role over its change, which carries its direction as a `trend`, each
`--` when the quote has none, and under them a graph of the quote's
recent prices with the day's opening price marked across it. A
block's key is its quote's symbol, so a board that reorders its quotes
moves blocks instead of rewriting their text. Before the first board the
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

-export([tree/1, clock_offset/0, clock/1, date/1, minute/1, price/2, change/1]).

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
                   ground := binary(),
                   board := none | board()}.

%% The graph's range: a card's prices are scaled onto it, so no price,
%% however large, leaves the widget format's integers.
-define(GRAPH_SCALE, 1000).

%% The layout, in pixels: the margin round the screen, the quotes panel's
%% width and the gap before it, the space between the clock, the date and
%% the time and their lines, and the space either side of a hairline.
-define(MARGIN, 56).
-define(PANEL, 520).
-define(PANEL_GAP, 48).
-define(DATE_GAP, 28).
-define(DATE_LINE, 36).
-define(TIME_GAP, 4).
-define(TIME_LINE, 16).
-define(RULE_GAP, 16).
-define(MONTHS, {<<"January">>, <<"February">>, <<"March">>, <<"April">>,
                 <<"May">>, <<"June">>, <<"July">>, <<"August">>,
                 <<"September">>, <<"October">>, <<"November">>,
                 <<"December">>}).
-define(WEEKDAYS, {<<"Monday">>, <<"Tuesday">>, <<"Wednesday">>,
                   <<"Thursday">>, <<"Friday">>, <<"Saturday">>,
                   <<"Sunday">>}).

-doc "The widget tree of `Model`.".
-spec tree(model()) -> erx_ui_model:tree().
tree(#{time := Time, board := Board, dial := Dial, ground := Ground}) ->
    Size = erx_dashboard_clock:size(),
    {stack, #{},
     [{image, #{image => Ground, image_type => png}, []},
      {row, #{pad => ?MARGIN},
       [{column, #{weight => 1},
         [{spacer, #{weight => 1}, []},
          centred({image, #{width => Size, height => Size, image => Dial,
                            image_type => png, alt => clock(Time)}, []}),
          gap(?DATE_GAP),
          centred({label, #{height => ?DATE_LINE, role => headline, text => date(Time)}, []}),
          gap(?TIME_GAP),
          centred({label, #{height => ?TIME_LINE, role => caption,
                            text => <<(clock(Time))/binary, " UTC">>}, []}),
          {spacer, #{weight => 1}, []}]},
        {spacer, #{width => ?PANEL_GAP}, []},
        {column, #{width => ?PANEL}, panel(Board)}]}]}.

-doc """
Where the clock's centre lies from the window's centre, `{Dx, Dy}` in
pixels, at any window size: the panel's width and the gap before it
take the right of the row, and the date and time lie under the clock in
a column centred on the rest. The ground's glow is drawn there.
""".
-spec clock_offset() -> {integer(), integer()}.
clock_offset() ->
    {-(?PANEL + ?PANEL_GAP) div 2, -(?DATE_GAP + ?DATE_LINE + ?TIME_GAP + ?TIME_LINE) div 2}.

panel(none) ->
    [panel_header(<<"Waiting for quotes">>)];
panel(#{credit := Credit, quotes := Quotes}) ->
    Rule = rule(),
    [panel_header(Credit), gap(20) | lists:join(Rule, [card(Quote) || Quote <- Quotes])].

%% The panel's title with the board's credit flush right on its baseline.
panel_header(Note) ->
    {row, #{height => 36},
     [{label, #{role => headline, text => <<"Markets">>}, []},
      {column, #{weight => 1},
       [{spacer, #{weight => 1}, []},
        flush_right({label, #{height => 16, role => caption, text => Note}, []}),
        gap(5)]}]}.

%% A hairline across the panel, between two quotes' blocks.
rule() ->
    {column, #{height => 2 * ?RULE_GAP + 1},
     [gap(?RULE_GAP),
      {image, #{width => ?PANEL, height => 1, image => erx_dashboard_pictures:rule(?PANEL),
                image_type => png}, []},
      gap(?RULE_GAP)]}.

gap(Height) ->
    {spacer, #{height => Height}, []}.

%% A node in the middle of a row of its own, and one at its end: the
%% spacers take the room the node leaves.
centred(Node) ->
    {row, #{}, [{spacer, #{weight => 1}, []}, Node, {spacer, #{weight => 1}, []}]}.

flush_right(Node) ->
    {row, #{}, [{spacer, #{weight => 1}, []}, Node]}.

%% A quote's block: its name over its status line, or its symbol when the
%% source gives no status, beside its price over its change, each `--`
%% when the quote has none; under them the graph of its recent prices,
%% which takes the block's room left over.
card(#{symbol := Symbol, name := Name, price := Price, change := Change,
       decimals := Decimals} = Quote) ->
    {column, #{key => Symbol, weight => 1},
     [{row, #{height => 48},
       [{column, #{weight => 1},
         [{label, #{height => 28, role => title, text => Name}, []},
          {label, #{height => 20, role => caption,
                    text => maps:get(status, Quote, Symbol)}, []}]},
        {column, #{width => 150},
         [flush_right({label, #{height => 28, role => figure,
                                text => or_none(Price, fun(P) -> price(P, Decimals) end)}, []}),
          flush_right(change_label(Change))]}]},
      gap(12),
      graph(Quote)]}.

%% The change in the colour of its direction, the renderer's to choose.
change_label(none) ->
    {label, #{height => 20, role => numeric, text => <<"--">>}, []};
change_label(Change) ->
    {label, #{height => 20, role => numeric, trend => direction(Change), text => change(Change)}, []}.

%% Which way a percent change moved, once rounded to the hundredths shown.
direction(Percent) ->
    case round(Percent * 100) of
        Hundredths when Hundredths > 0 -> up;
        Hundredths when Hundredths < 0 -> down;
        _Zero -> flat
    end.

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
    {graph, Props#{weight => 1, min => 0, max => ?GRAPH_SCALE}, []}.

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

-doc "The date of a wall-clock reading, as `Sunday, 15 November`.".
-spec date(calendar:datetime()) -> binary().
date({{_Year, Month, Day} = Date, _Time}) ->
    Weekday = element(calendar:day_of_the_week(Date), ?WEEKDAYS),
    iolist_to_binary([Weekday, ", ", integer_to_binary(Day), " ", element(Month, ?MONTHS)]).

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
A percent change rounded to two digits after the point, led by an arrow
up or down, U+2191 or U+2193, and a space for its sign: `1.25` up is
`<<16#2191/utf8, " 1.25%">>`, and `<<"0.00%">>` a change that rounds to
nothing.
""".
-spec change(number()) -> binary().
change(Percent) ->
    Hundredths = round(Percent * 100),
    Arrow = case direction(Percent) of
                up -> <<16#2191/utf8, " ">>;
                down -> <<16#2193/utf8, " ">>;
                flat -> <<>>
            end,
    iolist_to_binary([Arrow, grouped(abs(Hundredths) div 100),
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
