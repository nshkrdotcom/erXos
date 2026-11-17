%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_time_records).
-moduledoc """
The collector of `[time]`, the clock's record (docs/design-time.md,
"What /proc shows"), which `/proc/time/status` shows to every scope.

* `state` is the time page's, reported by `kernel`, as
  erx_clock_core:state/2 tells it from the page and the build's floor:
  `unset`, `boot`, `approximate` or `set`. A page whose sequence has run
  out is `{error, limit}`, as the reader refuses it.
* Every other attribute is the clock service's record, reported by
  `service`, as erx_clock:record/1 answers it in this domain. A value the
  record holds as `none`, nothing sampled or stepped since the service
  started, is `unknown`, since no type of the schema holds `none`. With no
  clock service running every such attribute is `{error, unavailable}`,
  and with one that does not answer within inspect_agent_wait
  milliseconds, `{timeout, inspect_agent_wait}`.
* `sample_from` and `step_from` name the kind of source of the last sample
  and of the last applied step, erx_clock_core's from(): `ntp ADDRESS`,
  `rtc` or `root`.

The page is read through erx_clock_nif:read/0 and the record asked of the
service in the runtime that collects; the pure core, record/3, takes both
answers and the floor as data.
""".

-export([collect/0]).
-export([record/3]).
-export_type([service/0]).

-include("generated/erx_abi.hrl").

%% The clock service's answer to the collector, or what stands in for it.
-type service() :: {ok, erx_clock_core:clock_record()} | {error, unavailable | failed} | {timeout, pos_integer()}.

-doc """
The clock's record, from the time page this runtime maps and the clock
service of this runtime; `{error, unsupported}` where the runtime has no
clock NIF, as on a development host's stock emulator.
""".
-spec collect() -> {ok, erx_schema:record()} | {error, unsupported}.
collect() ->
    try erx_clock_nif:read() of
        Read -> record(Read, erx_clock_core:build_floor(erx_build:facts()), service())
    catch
        error:undef -> {error, unsupported}
    end.

service() ->
    try erx_clock:record(?ERX_INSPECT_AGENT_WAIT)
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:{timeout, _} -> {timeout, ?ERX_INSPECT_AGENT_WAIT};
        exit:_ -> {error, failed}
    end.

-doc """
The clock's record from Read, erx_clock_nif:read/0's answer, Floor, the
build's (erx_clock_core:build_floor/1), and Service, the clock service's
answer, checked whole by erx_schema:validate_record/1.
""".
-spec record({ok, erx_clock_nif:page()} | {error, limit}, erx_clock_core:floor(), service()) ->
          {ok, erx_schema:record()}.
record(Read, Floor, Service) ->
    {ok, Keys} = erx_schema:attributes(clock),
    Attrs = #{Key => {service, value(Key, Service)} || Key <- Keys, Key =/= state},
    Record = #{schema => erx_schema:schema(), path => [time], kind => clock, id => time,
               attrs => Attrs#{state => {kernel, state(Read, Floor)}}, children => []},
    {ok, _} = erx_schema:validate_record(Record).

state({ok, Page}, Floor) -> {ok, erx_clock_core:state(Page, Floor)};
state({error, limit}, _Floor) -> {error, limit}.

%% Attribute Key's value from the service's answer: its record's, in the schema's type.
value(Key, {ok, Record}) -> shown(Key, maps:get(Key, Record));
value(_Key, Missed) -> Missed.

shown(_Key, none) -> unknown;
shown(server, Address) -> {ok, address(Address)};
shown(Key, {ntp, Address}) when Key =:= sample_from; Key =:= step_from -> {ok, <<"ntp ", (address(Address))/binary>>};
shown(Key, Kind) when Key =:= sample_from; Key =:= step_from -> {ok, atom_to_binary(Kind)};
shown(_Key, Value) -> {ok, Value}.

address(Address) -> list_to_binary(inet:ntoa(Address)).
