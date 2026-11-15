%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_time_records).
-moduledoc """
The collector of `[time]`, the clock's record (docs/design-time.md,
"What /proc shows"), which `/proc/time/status` shows to every scope.

* `state` is the time page's, reported by `kernel`: `unset` while its
  sequence and its offset are zero, so wall time is uptime counted from
  1970-01-01; `boot` while its sequence is zero and its offset is not,
  the boot's own reading; `set` once the page has changed this boot. A
  page whose sequence has run out is `{error, limit}`, as the reader
  refuses it.
* Every other attribute is the clock service's record, reported by
  `service`, and is `unsupported` until that service reports it.

The page is read through erx_clock_nif:read/0 in the runtime that
collects; the pure core, record/1, takes that answer as data.
""".

-export([collect/0]).
-export([record/1]).

-doc """
The clock's record, from the time page this runtime maps;
`{error, unsupported}` where the runtime has no clock NIF, as on a
development host's stock emulator.
""".
-spec collect() -> {ok, erx_schema:record()} | {error, unsupported}.
collect() ->
    try erx_clock_nif:read() of
        Read -> record(Read)
    catch
        error:undef -> {error, unsupported}
    end.

-doc "The clock's record from Read, erx_clock_nif:read/0's answer, checked whole by erx_schema:validate_record/1.".
-spec record({ok, erx_clock_nif:page()} | {error, limit}) -> {ok, erx_schema:record()}.
record(Read) ->
    {ok, Keys} = erx_schema:attributes(clock),
    Unreported = maps:from_list([{Key, {service, unsupported}} || Key <- Keys]),
    Attrs = Unreported#{state => {kernel, state(Read)}},
    Record = #{schema => erx_schema:schema(), path => [time], kind => clock, id => time,
               attrs => Attrs, children => []},
    {ok, _} = erx_schema:validate_record(Record).

state({ok, #{cold := true, offset := 0}}) -> {ok, unset};
state({ok, #{cold := true}}) -> {ok, boot};
state({ok, #{cold := false}}) -> {ok, set};
state({error, limit}) -> {error, limit}.
