%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_cmd_clock).
-moduledoc """
The command `clock` (docs/design-desktop-programs.md, "clock" and
"Shipping and starting"): opens one more clock window and returns once it
is open. It takes no arguments.

It follows erx_cmd's command shape, attributes and run/2, without naming
the behaviour: erx_cmd is erx_shell's, which the release erx_desk ships
in does not hold.
""".

-erx_command(clock).
-erx_usage("clock").

-export([run/2]).

-doc "Opens a clock window: `ok`, `{error, usage}` or the reason it did not open.".
-spec run([binary()], map()) -> ok | {error, usage} | {error, term()}.
run([], _Ctx) ->
    case erx_desk:open(clock) of
        ok -> ok;
        {error, no_display} -> {error, <<"no display">>};
        {error, _Reason} = Refused -> Refused
    end;
run(_Args, _Ctx) ->
    {error, usage}.
