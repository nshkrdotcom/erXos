%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_core).
-moduledoc """
ntpd's pure core (docs/design-time.md, "The client"): the server list read
from the start flags, and the schedule as one state machine.

servers/1 reads `ERX_START_FLAGS`' value: entries split at spaces, which
erx_ntp_exchange:servers/1's server-list rule must accept.

start/1 and step/2 are the schedule. Each answers the next action for the
effect process to perform and the state to hand back with that action's
result, so the order of the steps is the core's alone:

| Action | Result handed to step/2 |
| --- | --- |
| `{resolve, Names}` | `{resolved, Addresses}`, the names' addresses in DNS order |
| `{exchange, Address, poll \\| burst}` | `{exchanged, Outcome}`: a sample, a kiss, a drop or `{error, _}` |
| `{submit, Sample, Address}` | `{clock, Answer}`, the clock facet's answer |
| `{wait, Ms}` | `woke` |

The first poll of an address is a burst of up to four exchanges 2 s apart,
whose sample is the valid reply of least delay; a later poll is one
exchange. After a sample the wait is the poll interval, 64 s at first and
doubling after each answered sample up to 1024 s; an `{error, _}` answer
of the clock facet leaves the interval as it was. A poll with no sample
moves to the next address after the interval; when every address has
failed once in a row the interval doubles and the names are resolved again
after it. A resolution with no usable address is retried after 15 s,
doubling to 1024 s. `DENY` and `RSTR` remove the address for the rest of
the run, `RATE` doubles the interval, and any other kiss is discarded.
""".

-export([servers/1, start/1, step/2, request/2, interval/1, status/1]).
-export_type([state/0, action/0, event/0, status/0]).

-define(POLL_MIN_MS, 64000).
-define(POLL_MAX_MS, 1024000).
-define(RESOLVE_MIN_MS, 15000).
-define(BURST, 4).
-define(BURST_GAP_MS, 2000).
%% The addresses a run remembers as polled, and as denied: a bound, so a run
%% of rotating pool addresses cannot grow the state without limit.
-define(REMEMBERED_MAX, 64).

-type address() :: inet:ip4_address().
-type action() :: {resolve, [binary(), ...]}
                | {exchange, address(), poll | burst}
                | {submit, erx_ntp_sample:sample(), address()}
                | {wait, pos_integer()}.
-type event() :: {resolved, [address()]}
               | {exchanged, {sample, erx_ntp_sample:sample()} | {kiss, <<_:32>>} | {drop, erx_ntp_sample:drop()} | {error, term()}}
               | {clock, {ok, term()} | {error, term()}}
               | woke.
%% What the effect process is doing, and so which event comes next: the
%% stage alone decides which clause of step/2 takes it.
-type stage() :: resolving
               | {exchanging, address(), Left :: non_neg_integer(), Best :: none | erx_ntp_sample:sample()}
               | {submitting, address()}
               | {waiting, then()}.
-type then() :: resolve | poll | {burst, address(), non_neg_integer(), none | erx_ntp_sample:sample()}.
-opaque state() :: #{names := [binary(), ...], stage := stage(),
                     addresses := [address()], polled := [address()], denied := [address()],
                     failures := non_neg_integer(), interval := pos_integer(),
                     resolve_wait := pos_integer(), counts := counts(),
                     last := none | {address(), atom()}}.
%% What /proc/ntp shows of a run (status/1).
-type status() :: #{servers := [binary()], addresses := [address()], denied := [address()],
                    interval_s := pos_integer(), resolve_wait_s := pos_integer(),
                    last := unknown | {address(), atom()},
                    samples | dropped | kisses | silent := unknown | non_neg_integer()}.
-type counts() :: #{samples := non_neg_integer(), dropped := non_neg_integer(),
                    kisses := non_neg_integer(), silent := non_neg_integer()}.

%%% The server list

-doc """
The server list `ERX_START_FLAGS` names: `{ok, Names}`, or `{error,
no_servers}` for empty flags and `{error, bad_flags}` for more than 8
entries or one that is neither an IPv4 literal nor a host name.
""".
-spec servers(binary()) -> {ok, [binary(), ...]} | {error, no_servers | bad_flags}.
servers(Flags) when is_binary(Flags) ->
    case binary:split(Flags, <<" ">>, [global, trim_all]) of
        [] -> {error, no_servers};
        Names ->
            case erx_ntp_exchange:servers(Names) of
                true -> {ok, Names};
                false -> {error, bad_flags}
            end
    end.

%%% The schedule

-doc "The first action of a run over Names, and its state: the names are resolved at once.".
-spec start([binary(), ...]) -> {action(), state()}.
start([_ | _] = Names) ->
    resolve(#{names => Names, stage => resolving, addresses => [], polled => [], denied => [],
              failures => 0, interval => ?POLL_MIN_MS, resolve_wait => ?RESOLVE_MIN_MS,
              counts => #{samples => 0, dropped => 0, kisses => 0, silent => 0}, last => none}).

-doc "The next action once the last one's result is Event, and the state to hand back with its result.".
-spec step(event(), state()) -> {action(), state()}.
step({resolved, Found}, #{stage := resolving, denied := Denied, resolve_wait := Wait} = State) ->
    case usable(Found, Denied) of
        [] -> wait(Wait, resolve, State#{resolve_wait := double(Wait)});
        Addresses -> poll(State#{addresses := Addresses, failures := 0, resolve_wait := ?RESOLVE_MIN_MS})
    end;
step({exchanged, Verdict}, #{stage := {exchanging, Address, Left, Best}} = State) ->
    exchanged(Verdict, Address, Left, Best, State);
step({clock, Answer}, #{stage := {submitting, _Address}, interval := Interval} = State) ->
    Next = case Answer of
               {ok, _} -> double(Interval);
               {error, _} -> Interval
           end,
    wait(Interval, poll, State#{interval := Next, failures := 0});
step(woke, #{stage := {waiting, resolve}} = State) ->
    resolve(State);
step(woke, #{stage := {waiting, poll}} = State) ->
    poll(State);
step(woke, #{stage := {waiting, {burst, Address, Left, Best}}} = State) ->
    {{exchange, Address, burst}, State#{stage := {exchanging, Address, Left, Best}}}.

-doc """
The clock facet request of a sample from Address (docs/design-time.md,
"The clock facet"): its wall offset, distance and stratum, and the address.
""".
-spec request(erx_ntp_sample:sample(), address()) -> {sample, integer(), non_neg_integer(), 1..15, address()}.
request(#{offset := W, distance := Distance, stratum := Stratum}, Address) ->
    {sample, W, Distance, Stratum, Address}.

-doc "The poll interval in effect, in milliseconds.".
-spec interval(state()) -> pos_integer().
interval(#{interval := Interval}) -> Interval.

-doc """
What /proc/ntp shows of the run: the names, the addresses in use, the
address that last answered and how, the interval and the resolution
backoff in seconds, and the reply counts. Before the first exchange the
counts and the last answer are `unknown`, so nothing claims more history
than the run has.
""".
-spec status(state()) -> status().
status(#{names := Names, addresses := Addresses, denied := Denied, interval := Interval,
         resolve_wait := ResolveWait, counts := Counts, last := Last}) ->
    Exchanged = case Last of
                    none -> #{Key => unknown || Key := _ <- Counts#{last => none}};
                    _ -> Counts#{last => Last}
                end,
    Exchanged#{servers => Names, addresses => Addresses, denied => Denied, interval_s => Interval div 1000,
               resolve_wait_s => ResolveWait div 1000}.

%% One exchange's verdict. A kiss ends the poll; anything else that is no
%% sample counts as dropped or silent and the burst goes on.
exchanged({kiss, Code}, Address, Left, Best, #{counts := Counts} = State0) ->
    State = State0#{counts := bump(kisses, Counts), last := {Address, kiss(Code)}},
    case kiss(Code) of
        deny -> denied(remove(Address, State));
        rate -> finish(Address, Best, State#{interval := double(maps:get(interval, State))});
        other -> continue(Address, Left, Best, State)
    end;
exchanged({sample, Sample}, Address, Left, Best, #{counts := Counts} = State) ->
    continue(Address, Left, least_delay(Sample, Best),
             State#{counts := bump(samples, Counts), last := {Address, sample}});
exchanged({drop, Reason}, Address, Left, Best, #{counts := Counts} = State) ->
    continue(Address, Left, Best, State#{counts := bump(dropped, Counts), last := {Address, Reason}});
exchanged(_NoReply, Address, Left, Best, #{counts := Counts} = State) ->
    continue(Address, Left, Best, State#{counts := bump(silent, Counts), last := {Address, no_reply}}).

continue(Address, Left, Best, State) when Left > 0 ->
    wait(?BURST_GAP_MS, {burst, Address, Left - 1, Best}, State);
continue(Address, 0, Best, State) ->
    finish(Address, Best, State).

%% The poll's end: its best sample goes to the clock, or the poll failed.
finish(Address, Best, State) when is_map(Best) ->
    {{submit, Best, Address}, State#{stage := {submitting, Address}}};
finish(Address, none, #{addresses := [Address | Rest]} = State) ->
    failed(State#{addresses := Rest ++ [Address]}).

%% A poll without a sample: the next address after the interval, or, once
%% every address has failed in a row, a doubled interval and a new resolution.
failed(#{addresses := Addresses, failures := Failures, interval := Interval} = State)
  when Failures + 1 >= length(Addresses) ->
    wait(double(Interval), resolve, State#{interval := double(Interval), failures := 0});
failed(#{failures := Failures, interval := Interval} = State) ->
    wait(Interval, poll, State#{failures := Failures + 1}).

%% A denied address is gone rather than failed: the next address after the
%% interval, or a new resolution once none is left.
denied(#{addresses := [], interval := Interval} = State) ->
    wait(Interval, resolve, State#{failures := 0});
denied(#{interval := Interval} = State) ->
    wait(Interval, poll, State).

resolve(#{names := Names} = State) ->
    {{resolve, Names}, State#{stage := resolving}}.

poll(#{addresses := [Address | _], polled := Polled} = State) ->
    case lists:member(Address, Polled) of
        true -> {{exchange, Address, poll}, State#{stage := {exchanging, Address, 0, none}}};
        false -> {{exchange, Address, poll},
                  State#{stage := {exchanging, Address, ?BURST - 1, none},
                         polled := lists:sublist([Address | Polled], ?REMEMBERED_MAX)}}
    end.

wait(Ms, Then, State) ->
    {{wait, Ms}, State#{stage := {waiting, Then}}}.

remove(Address, #{addresses := Addresses, polled := Polled, denied := Denied} = State) ->
    State#{addresses := lists:delete(Address, Addresses), polled := lists:delete(Address, Polled),
           denied := lists:sublist([Address | lists:delete(Address, Denied)], ?REMEMBERED_MAX)}.

%% The addresses of a resolution in DNS order, once each, without the denied.
usable(Found, Denied) ->
    lists:reverse(lists:foldl(fun(A, Seen) ->
                                      case lists:member(A, Seen) orelse lists:member(A, Denied) of
                                          true -> Seen;
                                          false -> [A | Seen]
                                      end
                              end, [], Found)).

least_delay(Sample, none) -> Sample;
least_delay(#{delay := D} = Sample, #{delay := Best}) when D < Best -> Sample;
least_delay(_Sample, Best) -> Best.

kiss(<<"DENY">>) -> deny;
kiss(<<"RSTR">>) -> deny;
kiss(<<"RATE">>) -> rate;
kiss(_Code) -> other.

double(Ms) -> min(2 * Ms, ?POLL_MAX_MS).

bump(Key, Counts) -> maps:update_with(Key, fun(N) -> N + 1 end, Counts).
