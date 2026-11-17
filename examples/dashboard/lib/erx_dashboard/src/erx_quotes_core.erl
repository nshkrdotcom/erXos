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
replaces it. `failure` is the reason the last round failed, the first
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
""".

-export([new/2, tick/3, outcome/5]).

-export_type([state/0, quote/0, action/0, outcome/0]).

-type reason() :: erx_quotes_http:reason().
-type quote() :: #{value := none | {Price :: float(), Change :: none | float(),
                                    Source :: atom(), FetchedAt :: integer()},
                   failure := none | {reason(), At :: integer()},
                   failed_rounds := non_neg_integer(),
                   next_at := integer(),
                   trying := none | {Index :: pos_integer(), FirstReason :: none | reason()}}.
-type source() :: #{not_before := integer(), held := none | reason()}.
-type state() :: #{table := erx_quotes_table:table(),
                   quotes := #{atom() => quote()},
                   sources := #{atom() => source()}}.
-type action() :: {fetch, Quote :: atom(), Source :: atom(), Url :: binary()} | render.
-type outcome() :: {value, float(), none | float()}
                 | {error, reason(), RetryAfter :: none | pos_integer()}.

-define(MAX_WAIT_MS, 900000).
%% Past this many doublings every period of the table (5 s and up) is
%% beyond the cap already, so the exponent stops growing with the count.
-define(MAX_DOUBLINGS, 20).

-doc "The state at monotonic time `Now`: every quote due, no value, no source held back.".
-spec new(erx_quotes_table:table(), integer()) -> state().
new(#{quotes := Quotes, sources := Sources} = Table, Now) ->
    #{table => Table,
      quotes => maps:from_list(
                  [{Name, #{value => none, failure => none, failed_rounds => 0,
                            next_at => Now, trying => none}}
                   || {Name, _Row} <- Quotes]),
      sources => maps:map(fun(_Name, _Row) -> #{not_before => Now, held => none} end,
                          Sources)}.

-doc """
Starts every round that is due at `Now`, in the table's order, and asks
for a render, since the ages the screen shows have moved.
""".
-spec tick(state(), integer(), float()) -> {state(), [action()]}.
tick(#{table := #{quotes := Rows}} = State, Now, Jitter) ->
    {Next, Actions} =
        lists:foldl(fun({Name, _Row}, {S, Acc}) ->
                            case due(Name, S, Now) of
                                true ->
                                    {S2, More} = ask(Name, 1, none, S, Now, Jitter),
                                    {S2, Acc ++ More};
                                false -> {S, Acc}
                            end
                    end, {State, []}, Rows),
    {Next, [Action || Action <- Actions, Action =/= render] ++ [render]}.

due(Name, #{quotes := Quotes}, Now) ->
    case Quotes of
        #{Name := #{trying := none, next_at := At}} -> Now >= At;
        #{Name := _InFlight} -> false
    end.

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

answered(Quote, Index, _First, {value, Price, Change}, State, Now, _Jitter) ->
    Source = source_name(Quote, Index, State),
    #{period := Period} = row(Quote, State),
    {update_quote(Quote, #{value => {Price, Change, Source, Now}, failure => none,
                           failed_rounds => 0, next_at => Now + Period,
                           trying => none}, State),
     [render]};
answered(Quote, Index, First, {error, Reason, RetryAfter}, State, Now, Jitter) ->
    Source = source_name(Quote, Index, State),
    Held = hold(Source, Reason, RetryAfter, State, Now),
    ask(Quote, Index + 1, first(First, Reason), Held, Now, Jitter).

hold(_Source, _Reason, none, State, _Now) ->
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
