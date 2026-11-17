%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_core).
-moduledoc """
The live quotes' state machine (docs/design-quotes.md, "A quote's
state" and "Algorithms"): new/2 starts every quote with no value,
tick/3 starts the rounds that are due, and outcome/5 takes a source's
answer. Each returns the next state and the actions the effect process
carries out, `{fetch, Quote, Source, Url}` and `render`. Times are
monotonic milliseconds and `Jitter` a number in [0.8, 1.2) the effect
process draws, so the core reads no clock and no generator.

A quote's `value` is the last price it received, paired with its change,
the source that gave it and the time it was fetched; only a value
replaces it. Its `samples` are the last samples/0 prices it received,
oldest first, which the screen draws as a graph. `failure` is the reason the last round failed, the first
source's, and goes when a round succeeds. `trying` is the round in
flight: the index of the source asked and the first source's reason if
it failed or was passed. A round is due when `next_at` has passed and
none is in flight; it asks the quote's sources in order, passing over a
source whose `not_before`, the time its last `Retry-After` named, has
not passed, with the reason it was held back for. A source's hold
belongs to the source, so a source two quotes share is held back for
both. After a failed round the quote waits its period doubled for each
failed round in a row, up to 15 minutes, times the jitter, and no less
than until the earliest of its sources is free again.

A quote whose sources include one with a `history` asks that source for
a day of 15 min closes at start and then once an hour, answered or not,
as the action `{history, Quote, Source}`, and never while the source is
held back; a failed one waits for the next, and one answered with a
`Retry-After` holds the source back as a round's does (history_failed/5).
history/3 takes the entries an answer carried and makes them the
quote's `series`, oldest first,
the last buckets/0 of them. The series keeps the source's times, which
the kiosk's wall clock may lag: a live price joins it by the wall-clock
second it was read at, and in a bucket after the series' last one it is
appended after the skipped buckets, each repeating the last close,
unless it skipped more than an hour of them, which makes the series
`none` until the next history; in the last bucket or an earlier one it
replaces the last close. Until a history arrives the series is `none`
and the screen draws the samples.
""".

-export([new/2, tick/3, outcome/5, history/3, history_failed/5, history_url/2, samples/0,
         bucket/0, buckets/0]).

-export_type([state/0, quote/0, action/0, outcome/0, point/0]).

-type reason() :: erx_quotes_http:reason().
-type quote() :: #{value := none | {Price :: float(), Change :: none | float(),
                                    Source :: atom(), FetchedAt :: integer()},
                   samples := [float()],
                   series := none | [point()],
                   history_at := integer(),
                   failure := none | {reason(), At :: integer()},
                   failed_rounds := non_neg_integer(),
                   next_at := integer(),
                   trying := none | {Index :: pos_integer(), FirstReason :: none | reason()}}.
-type source() :: #{not_before := integer(), held := none | reason()}.
-type state() :: #{table := erx_quotes_table:table(),
                   quotes := #{atom() => quote()},
                   sources := #{atom() => source()}}.
-type action() :: {fetch, Quote :: atom(), Source :: atom(), Url :: binary()}
                | {history, Quote :: atom(), Source :: atom()}
                | render.
%% A bucket of the series: its start, a second on the source's clock, and
%% its close.
-type point() :: {Start :: integer(), Close :: float()}.
-type outcome() :: {value, float(), none | float(), WallSecond :: integer()}
                 | {error, reason(), RetryAfter :: none | pos_integer()}.

-define(MAX_WAIT_MS, 900000).
%% The prices a quote keeps: half an hour of the table's 10 s period.
-define(SAMPLES, 180).
%% Past this many doublings every period of the table (5 s and up) is
%% beyond the cap already, so the exponent stops growing with the count.
-define(MAX_DOUBLINGS, 20).
%% The series' bucket in wall-clock seconds, and the buckets it keeps: a day.
-define(BUCKET, 900).
-define(BUCKETS, 96).
%% Monotonic milliseconds between two history requests of a quote.
-define(HISTORY_MS, 3600000).
%% The most buckets a live price may skip and still join the series: an
%% hour. A longer gap on our side drops the series until the next history.
-define(MAX_GAP, 4).

-doc "The most prices a quote keeps in its `samples`.".
-spec samples() -> pos_integer().
samples() -> ?SAMPLES.

-doc "The length of a bucket of the series, in seconds.".
-spec bucket() -> pos_integer().
bucket() -> ?BUCKET.

-doc "The most buckets a quote keeps in its `series`.".
-spec buckets() -> pos_integer().
buckets() -> ?BUCKETS.

-doc "The state at monotonic time `Now`: every quote due, no value, no source held back.".
-spec new(erx_quotes_table:table(), integer()) -> state().
new(#{quotes := Quotes, sources := Sources} = Table, Now) ->
    #{table => Table,
      quotes => maps:from_list(
                  [{Name, #{value => none, samples => [], series => none, history_at => Now,
                            failure => none, failed_rounds => 0, next_at => Now,
                            trying => none}}
                   || {Name, _Row} <- Quotes]),
      sources => maps:map(fun(_Name, _Row) -> #{not_before => Now, held => none} end,
                          Sources)}.

-doc """
Starts every round and every history request that is due at `Now`, in
the table's order, and asks for a render, since the ages the screen
shows have moved.
""".
-spec tick(state(), integer(), float()) -> {state(), [action()]}.
tick(#{table := #{quotes := Rows}} = State, Now, Jitter) ->
    {Next, Actions} =
        lists:foldl(fun({Name, _Row}, {S, Acc}) ->
                            {S2, Round} = case due(Name, S, Now) of
                                              true -> ask(Name, 1, none, S, Now, Jitter);
                                              false -> {S, []}
                                          end,
                            {S3, History} = history_due(Name, S2, Now),
                            {S3, Acc ++ Round ++ History}
                    end, {State, []}, Rows),
    {Next, [Action || Action <- Actions, Action =/= render] ++ [render]}.

due(Name, #{quotes := Quotes}, Now) ->
    case Quotes of
        #{Name := #{trying := none, next_at := At}} -> Now >= At;
        #{Name := _InFlight} -> false
    end.

%% A quote's history is asked of the first of its sources that names one,
%% at start and then every ?HISTORY_MS from the last request, whether or
%% not it was answered: a failed request waits for the next. A source
%% held back is not asked until its `not_before`, as by a round. httpc's
%% timeouts end a request long before the next is due, so at most one
%% per quote is in flight.
history_due(Name, #{quotes := Quotes} = State, Now) ->
    #{history_at := At} = maps:get(Name, Quotes),
    case history_source(Name, State) of
        none ->
            {State, []};
        Source ->
            #{not_before := NotBefore} = source_state(Source, State),
            case Now >= max(At, NotBefore) of
                true ->
                    {update_quote(Name, #{history_at => Now + ?HISTORY_MS}, State),
                     [{history, Name, Source}]};
                false ->
                    {State, []}
            end
    end.

history_source(Name, #{table := #{sources := Rows}} = State) ->
    #{sources := Names} = row(Name, State),
    case [Source || Source <- Names, is_map_key(history, maps:get(Source, Rows))] of
        [Source | _] -> Source;
        [] -> none
    end.

-doc """
Takes the entries a history answer for `Quote` carried, `{Start, Close}`
oldest first, each start on bucket/0 steps and later than the one before
(erx_quotes_extract:history/2), and makes them the quote's series whole:
joined one by one, so gaps repeat the close before them, and trimmed to
the last buckets/0.
""".
-spec history(state(), atom(), [point(), ...]) -> {state(), [action()]}.
history(State, Quote, Entries) ->
    Series = lists:foldl(fun({Start, Close}, Acc) -> join(Acc, Start, Close, infinity) end,
                         [], Entries),
    {update_quote(Quote, #{series => Series}, State), [render]}.

-doc """
Takes the failure of the history request `Quote` had in flight, at
monotonic time `Now`. A `RetryAfter` holds its source back from rounds
and histories alike, for `Reason`, as a round's does; a failure without
one changes nothing, and the quote asks again at its next hourly
request.
""".
-spec history_failed(state(), atom(), reason(), none | pos_integer(), integer()) ->
          {state(), [action()]}.
history_failed(State, Quote, Reason, RetryAfter, Now) ->
    {hold(history_source(Quote, State), Reason, RetryAfter, State, Now), []}.

-doc """
The URL that asks `Source`, a source row with a `history`, for the day
up to the wall-clock second `Wall`: its history URL with `since` the
start of the bucket a day before `Wall`.
""".
-spec history_url(erx_quotes_table:source(), integer()) -> binary().
history_url(#{history := #{url := Url}}, Wall) ->
    Since = start_of(Wall - ?BUCKETS * ?BUCKET),
    <<Url/binary, "&since=", (integer_to_binary(Since))/binary>>.

-doc """
Takes the outcome of the request a round of `Quote` has in flight. An
outcome for a quote with no round in flight changes nothing.
""".
-spec outcome(state(), atom(), outcome(), integer(), float()) -> {state(), [action()]}.
outcome(#{quotes := Quotes} = State, Quote, Outcome, Now, Jitter) ->
    case Quotes of
        #{Quote := #{trying := {Index, First}}} ->
            answered(Quote, Index, First, Outcome, State, Now, Jitter);
        #{} ->
            {State, []}
    end.

answered(Quote, Index, _First, {value, Price, Change, Wall}, State, Now, _Jitter) ->
    Source = source_name(Quote, Index, State),
    #{period := Period} = row(Quote, State),
    #{samples := Samples, series := Series} = maps:get(Quote, maps:get(quotes, State)),
    {update_quote(Quote, #{value => {Price, Change, Source, Now},
                           samples => last(Samples ++ [Price]),
                           series => join(Series, Wall, Price, ?MAX_GAP), failure => none,
                           failed_rounds => 0, next_at => Now + Period,
                           trying => none}, State),
     [render]};
answered(Quote, Index, First, {error, Reason, RetryAfter}, State, Now, Jitter) ->
    Source = source_name(Quote, Index, State),
    Held = hold(Source, Reason, RetryAfter, State, Now),
    ask(Quote, Index + 1, first(First, Reason), Held, Now, Jitter).

hold(_Source, _Reason, none, State, _Now) ->
    State;
%% A hold only lengthens: a round and a history may both be answered with
%% a `Retry-After`, and the shorter never ends the longer.
hold(Source, _Reason, RetryAfter, #{sources := Sources} = State, Now)
  when map_get(not_before, map_get(Source, Sources)) >= Now + RetryAfter ->
    State;
hold(Source, Reason, RetryAfter, #{sources := Sources} = State, Now) ->
    State#{sources := Sources#{Source := #{not_before => Now + RetryAfter,
                                           held => Reason}}}.

%% Asks the quote's sources from `Index` on: a source still held back is
%% passed with the reason it was held for, the first free one is fetched,
%% and when none is left the round ends failed.
ask(Quote, Index, First, State, Now, Jitter) ->
    #{sources := Names} = row(Quote, State),
    case Index > length(Names) of
        true ->
            fail(Quote, First, State, Now, Jitter);
        false ->
            Source = lists:nth(Index, Names),
            case source_state(Source, State) of
                #{not_before := NotBefore, held := Held} when NotBefore > Now ->
                    ask(Quote, Index + 1, first(First, Held), State, Now, Jitter);
                #{} ->
                    #{url := Url} = source_row(Source, State),
                    {update_quote(Quote, #{trying => {Index, First}}, State),
                     [{fetch, Quote, Source, Url}]}
            end
    end.

%% The round's reason is the first source's, whether it failed or was passed.
first(none, Reason) -> Reason;
first(First, _Reason) -> First.

fail(Quote, Reason, State, Now, Jitter) ->
    #{period := Period, sources := Names} = row(Quote, State),
    #{failed_rounds := Failed} = maps:get(Quote, maps:get(quotes, State)),
    Rounds = Failed + 1,
    Wait = round(min(Period bsl min(Rounds, ?MAX_DOUBLINGS), ?MAX_WAIT_MS) * Jitter),
    Free = lists:min([maps:get(not_before, source_state(Name, State)) || Name <- Names]),
    {update_quote(Quote, #{failure => {Reason, Now}, failed_rounds => Rounds,
                           next_at => max(Now + Wait, Free), trying => none}, State),
     [render]}.

%% The last ?SAMPLES of a quote's prices.
last(Samples) when length(Samples) > ?SAMPLES -> tl(Samples);
last(Samples) -> Samples.

%% `Series` with `Price`, read at the wall-clock second `Wall`, joined:
%% in a bucket after the series' last one it is appended after the
%% buckets skipped, each repeating the last close, unless more than
%% `MaxGap` were skipped, which makes the series `none`; in the last
%% bucket or an earlier one, as when the kiosk's clock lags the source's
%% or stepped back, it replaces the last close, so the series keeps the
%% source's times and the line ends at the live price.
%% A history's entries join with a `MaxGap` of `infinity`, since a bucket
%% the source left out had no trades; a live price with ?MAX_GAP, since
%% a longer gap on our side is time nothing was known about.
%% Only the last ?BUCKETS are kept, so at most that many skipped buckets
%% are made, the ones just before the new bucket. A series of `none`
%% stays `none`: only a history starts one.
join(none, _Wall, _Price, _MaxGap) ->
    none;
join([], Wall, Price, _MaxGap) ->
    [{start_of(Wall), Price}];
join(Series, Wall, Price, MaxGap) ->
    {Last, Close} = lists:last(Series),
    case start_of(Wall) of
        Start when Start =< Last ->
            lists:droplast(Series) ++ [{Last, Price}];
        Start when (Start - Last) div ?BUCKET - 1 > MaxGap ->
            none;
        Start ->
            From = max(Last + ?BUCKET, Start - (?BUCKETS - 1) * ?BUCKET),
            Skipped = [{Time, Close} || Time <- lists:seq(From, Start - ?BUCKET, ?BUCKET)],
            keep(Series ++ Skipped ++ [{Start, Price}])
    end.

keep(Series) ->
    lists:nthtail(max(length(Series) - ?BUCKETS, 0), Series).

%% The start of the bucket that holds the wall-clock second `Wall`,
%% rounded down, before 1970 too.
start_of(Wall) ->
    Wall - (Wall rem ?BUCKET + ?BUCKET) rem ?BUCKET.

update_quote(Quote, Changes, #{quotes := Quotes} = State) ->
    State#{quotes := Quotes#{Quote := maps:merge(maps:get(Quote, Quotes), Changes)}}.

row(Quote, #{table := #{quotes := Rows}}) ->
    {Quote, Row} = lists:keyfind(Quote, 1, Rows),
    Row.

source_name(Quote, Index, State) ->
    lists:nth(Index, maps:get(sources, row(Quote, State))).

source_row(Source, #{table := #{sources := Rows}}) ->
    maps:get(Source, Rows).

source_state(Source, #{sources := Sources}) ->
    maps:get(Source, Sources).
