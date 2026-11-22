%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ntp_records).
-moduledoc """
The collector of `[ntp]`, ntpd's state (docs/design-time.md, "What /proc
shows"), which `/proc/ntp/status` shows to the whole-machine scope. It is
meant to run in the runtime of ntpd's session, whose own state it reports,
so every attribute is `runtime`'s; until the query worker routes `[ntp]`
there (docs/todo-runtime.md, "time, ntpd"), the system domain's runtime answers
record(unsupported) instead (erx_inspector).

* The values are erx_ntp_core:status/1's, as erx_ntpd:status/1 answers
  them: addresses as text, the last answer as its address and how it
  answered, a kiss as one of the known atoms, never the server's bytes;
  the counts and the last answer `unknown` before the first exchange.
* With no ntpd running in this runtime, every attribute is `{error,
  unavailable}`; with one that does not answer within inspect_agent_wait
  milliseconds, as while it waits on an exchange or the clock facet,
  `{timeout, inspect_agent_wait}`.

The pure core, record/1, takes ntpd's answer as data.
""".

-export([collect/0]).
-export([record/1]).

-include("generated/erx_abi.hrl").

%% ntpd's answer to the collector, or what stands in for it.
-type answer() :: {ok, map()} | {error, unavailable} | {timeout, pos_integer()} | unsupported.

-doc "ntpd's record from the ntpd of this runtime.".
-spec collect() -> {ok, erx_schema:record()}.
collect() ->
    record(try erx_ntpd:status(?ERX_INSPECT_AGENT_WAIT)
           catch
               %% No ntpd application in this runtime's release.
               error:undef -> {error, unavailable}
           end).

-doc "ntpd's record from Answer, checked whole by erx_schema:validate_record/1.".
-spec record(answer()) -> {ok, erx_schema:record()}.
record(Answer) ->
    {ok, Keys} = erx_schema:attributes(ntp),
    Record = #{schema => erx_schema:schema(), path => [ntp], kind => ntp, id => ntp,
               attrs => #{Key => {runtime, value(Key, Answer)} || Key <- Keys}, children => []},
    {ok, _} = erx_schema:validate_record(Record).

value(Key, {ok, Status}) -> shown(Key, maps:get(Key, Status));
value(_Key, Missed) -> Missed.

shown(_Key, unknown) -> unknown;
shown(Key, Addresses) when Key =:= addresses; Key =:= denied -> {ok, [address(Address) || Address <- Addresses]};
shown(last, {Address, How}) -> {ok, <<(address(Address))/binary, " ", (atom_to_binary(How))/binary>>};
shown(_Key, Value) -> {ok, Value}.

address(Address) -> list_to_binary(inet:ntoa(Address)).
