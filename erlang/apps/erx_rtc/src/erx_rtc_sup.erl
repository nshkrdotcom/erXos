%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_rtc_sup).
-moduledoc """
The supervisor of the system domain's real-time clocks (docs/design-time.md,
"The real-time clock at boot"): one erx_rtc_pl031 child for each device
record of role `rtc` and peripheral `pl031` the root wrote, which the
manifest gives the system domain by its unit's holder. A machine whose
manifest gives the system domain none, the Raspberry Pi 4, has no child,
and its clock keeps the approximate start. A refused record is logged and
starts no child, so the clock keeps its start rather than the boot failing
for a clock it can do without. Each child is temporary and reads its clock
once, so no restart reads it again.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-doc "Starts the supervisor, registered as erx_rtc_sup.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, [child(Spec) || Spec <- records()]}}.

records() ->
    case erx_device_record:find(rtc, pl031) of
        {ok, Specs} -> Specs;
        {error, Reason} ->
            logger:warning("erx_rtc_sup: the real-time clock's record refused: ~0p", [Reason]),
            []
    end.

child(#{path := Path} = Spec) ->
    #{id => {erx_rtc_pl031, Path},
      start => {erx_rtc_pl031, start_link, [Spec]},
      restart => temporary,
      shutdown => brutal_kill,
      type => worker,
      modules => [erx_rtc_pl031]}.
