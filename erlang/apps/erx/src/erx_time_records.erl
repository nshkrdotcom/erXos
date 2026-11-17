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
  `service`, and is `unsupported` until that service reports it.

The page is read through erx_clock_nif:read/0 in the runtime that
collects; the pure core, record/2, takes that answer and the floor as data.
""".

-export([collect/0]).
-export([record/2]).

-doc """
The clock's record, from the time page this runtime maps;
`{error, unsupported}` where the runtime has no clock NIF, as on a
development host's stock emulator.
""".
-spec collect() -> {ok, erx_schema:record()} | {error, unsupported}.
collect() ->
    try erx_clock_nif:read() of
        Read -> record(Read, erx_clock_core:build_floor(erx_build:facts()))
    catch
        error:undef -> {error, unsupported}
    end.

-doc """
The clock's record from Read, erx_clock_nif:read/0's answer, and Floor,
the build's (erx_clock_core:build_floor/1), checked whole by
erx_schema:validate_record/1.
""".
-spec record({ok, erx_clock_nif:page()} | {error, limit}, erx_clock_core:build_floor()) -> {ok, erx_schema:record()}.
record(Read, Floor) ->
    {ok, Keys} = erx_schema:attributes(clock),
    Unreported = maps:from_list([{Key, {service, unsupported}} || Key <- Keys]),
    Attrs = Unreported#{state => {kernel, state(Read, Floor)}},
    Record = #{schema => erx_schema:schema(), path => [time], kind => clock, id => time,
               attrs => Attrs, children => []},
    {ok, _} = erx_schema:validate_record(Record).

state({ok, Page}, Floor) -> {ok, erx_clock_core:state(Page, Floor)};
state({error, limit}, _Floor) -> {error, limit}.
