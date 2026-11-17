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
| `{resolve, Name}` | `{resolved, Addresses}`, the name's addresses in DNS order |
| `{exchange, Address, poll \\| burst}` | `{exchanged, Outcome}`: a sample, a kiss, a drop or `{error, _}` |
| `{submit, Sample, Address}` | `{clock, Answer}`, the clock facet's answer |
| `{wait, Ms}` | `woke` |

A round resolves the names one at a time, in order, and polls the
addresses of each before it resolves the next, so the first usable
address is polled as soon as its name is resolved. The first poll of an
address is a burst of up to four exchanges 2 s apart, whose sample is the
valid reply of least delay; a later poll is one exchange. After a sample
the wait is the poll interval, 64 s at first and doubling after each
answered sample up to 1024 s; an `{error, _}` answer of the clock facet
leaves the interval as it was. A poll with no sample moves to the next
address, at once when that address has not been polled, else after the
interval; once every address resolved so far has failed in a row, the
next name is resolved at once, and once every name has been, the interval
doubles and a new round starts after it. A round that ends with no usable
address, none found or every one denied, starts again after 15 s,
doubling to 1024 s. `DENY` and `RSTR`
remove the address for the rest of the run, `RATE` doubles the interval,
and any other kiss is discarded.

The run remembers at most as many denied addresses as /proc/ntp's
`denied` shows (abi/inspection.txt's `net_addresses`). Once that list is
full, only an address the run has polled, which no denial has removed, is
admitted, so a denial past the bound needs no record: no denied address
is polled again, and the state stays bounded.
""".

-export([servers/1, start/1, step/2, request/2, interval/1, status/1]).
-export_type([state/0, action/0, event/0, status/0]).

-define(POLL_MIN_MS, 64000).
-define(POLL_MAX_MS, 1024000).
-define(RESOLVE_MIN_MS, 15000).
-define(BURST, 4).
-define(BURST_GAP_MS, 2000).
%% The addresses a run remembers as polled: a bound, so a run of rotating
%% pool addresses cannot grow the state without limit.
-define(POLLED_MAX, 64).

-type address() :: inet:ip4_address().
-type action() :: {resolve, binary()}
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
-type then() :: new_round | poll | {burst, address(), non_neg_integer(), none | erx_ntp_sample:sample()}.
%% unresolved: the names this round has still to resolve. addresses: those
%% the round has resolved and not denied, the one in use first. failures:
%% the polls without a sample in a row since the last sample or the round's
%% start. denied never shrinks, so once it is full admitted/2 admits only
%% polled addresses for the rest of the run.
-opaque state() :: #{names := [binary(), ...], unresolved := [binary()], stage := stage(),
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

-doc "The first action of a run over Names, and its state: the first name is resolved at once.".
-spec start([binary(), ...]) -> {action(), state()}.
start([_ | _] = Names) ->
    new_round(#{names => Names, unresolved => Names, stage => resolving, addresses => [], polled => [],
            denied => [], failures => 0, interval => ?POLL_MIN_MS, resolve_wait => ?RESOLVE_MIN_MS,
            counts => #{samples => 0, dropped => 0, kisses => 0, silent => 0}, last => none}).

-doc "The next action once the last one's result is Event, and the state to hand back with its result.".
-spec step(event(), state()) -> {action(), state()}.
step({resolved, Found}, #{stage := resolving, addresses := Addresses} = State) ->
    %% A name's new addresses go first, so its first is polled now; the
    %% addresses before them have all failed in a row, or none was resolved.
    case usable(Found, State) of
        [] -> exhausted(State);
        New -> poll(State#{addresses := New ++ Addresses, resolve_wait := ?RESOLVE_MIN_MS})
    end;
step({exchanged, Verdict}, #{stage := {exchanging, Address, Left, Best}} = State) ->
    exchanged(Verdict, Address, Left, Best, State);
step({clock, Answer}, #{stage := {submitting, _Address}, interval := Interval} = State) ->
    Next = case Answer of
               {ok, _} -> double(Interval);
               {error, _} -> Interval
           end,
    wait(Interval, poll, State#{interval := Next, failures := 0});
step(woke, #{stage := {waiting, new_round}} = State) ->
    new_round(State);
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

%% A poll without a sample counts as failed; a denied address is gone rather
%% than failed. Either way the next address, or, once every address left has
%% failed in a row, the round goes on.
failed(#{failures := Failures} = State) ->
    next(State#{failures := Failures + 1}).

denied(State) ->
    next(State).

next(#{addresses := Addresses, failures := Failures} = State) when Failures >= length(Addresses) ->
    exhausted(State);
next(#{addresses := [Address | _], interval := Interval} = State) ->
    %% An address never polled has never been asked, so its first poll, the
    %% burst, needs no wait; an address polled before waits the interval.
    case polled(Address, State) of
        true -> wait(Interval, poll, State);
        false -> poll(State)
    end.

%% Every address resolved so far has failed in a row: the next name at once;
%% once every name has been resolved, a new round after the doubled interval,
%% or after the resolution backoff when the round ends with no usable
%% address, none found or every one denied.
exhausted(#{unresolved := [_ | _]} = State) ->
    resolve(State);
exhausted(#{addresses := [], resolve_wait := Wait} = State) ->
    wait(Wait, new_round, State#{resolve_wait := double(Wait)});
exhausted(#{interval := Interval} = State) ->
    wait(double(Interval), new_round, State#{interval := double(Interval)}).

new_round(#{names := Names} = State) ->
    resolve(State#{unresolved := Names, addresses := [], failures := 0}).

resolve(#{unresolved := [Name | Rest]} = State) ->
    {{resolve, Name}, State#{stage := resolving, unresolved := Rest}}.

poll(#{addresses := [Address | _], polled := Polled} = State) ->
    case polled(Address, State) of
        true -> {{exchange, Address, poll}, State#{stage := {exchanging, Address, 0, none}}};
        false -> {{exchange, Address, poll},
                  State#{stage := {exchanging, Address, ?BURST - 1, none},
                         polled := lists:sublist([Address | Polled], ?POLLED_MAX)}}
    end.

wait(Ms, Then, State) ->
    {{wait, Ms}, State#{stage := {waiting, Then}}}.

%% Whether the run has polled Address, so its next poll is one exchange.
polled(Address, #{polled := Polled}) ->
    lists:member(Address, Polled).

%% A denied address leaves the addresses and the polled for good, and is
%% remembered while the denied list has room; past it, admitted/2 admits
%% only polled addresses, so it is never polled again either way.
remove(Address, #{addresses := Addresses, polled := Polled, denied := Denied} = State) ->
    Remembered = case length(Denied) < denied_max() of
                     true -> [Address | Denied];
                     false -> Denied
                 end,
    State#{addresses := lists:delete(Address, Addresses), polled := lists:delete(Address, Polled),
           denied := Remembered}.

%% A resolution's addresses in DNS order, once each, leaving out those the
%% round already has and those the run does not admit.
usable(Found, #{addresses := Addresses} = State) ->
    lists:reverse(lists:foldl(fun(A, Seen) ->
                                      case lists:member(A, Seen) orelse lists:member(A, Addresses)
                                          orelse not admitted(A, State) of
                                          true -> Seen;
                                          false -> [A | Seen]
                                      end
                              end, [], Found)).

%% Whether the run may poll Address: never a denied one, and once the denied
%% list is full, only one it has polled, since a denial past the bound is not
%% remembered.
admitted(Address, #{denied := Denied, polled := Polled}) ->
    case length(Denied) < denied_max() of
        true -> not lists:member(Address, Denied);
        false -> lists:member(Address, Polled)
    end.

%% The denied list's bound, the most addresses /proc/ntp's `denied` shows.
denied_max() ->
    {ok, {list, _Element, Max}} = erx_schema:type(net_addresses),
    Max.

least_delay(Sample, none) -> Sample;
least_delay(#{delay := D} = Sample, #{delay := Best}) when D < Best -> Sample;
least_delay(_Sample, Best) -> Best.

kiss(<<"DENY">>) -> deny;
kiss(<<"RSTR">>) -> deny;
kiss(<<"RATE">>) -> rate;
kiss(_Code) -> other.

double(Ms) -> min(2 * Ms, ?POLL_MAX_MS).

bump(Key, Counts) -> maps:update_with(Key, fun(N) -> N + 1 end, Counts).
