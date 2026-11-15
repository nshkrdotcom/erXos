%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_reboot).
-moduledoc """
`reboot [-lpq]` and `halt [-lpq]`: end the machine, as FreeBSD's
reboot(8) and halt(8) do (sbin/reboot/reboot.c), one program under two
names. `reboot` resets the machine and `halt` powers it off; `halt` is
erx_cmd_halt, which runs this module as FreeBSD's link runs reboot.c, and
the name the command ran under picks its end.

The request is the end alone (docs/design-system.md, "A session's
request"): `-p` makes `reboot`'s end a power-off, as FreeBSD's does, and
is plain `halt` for `halt`. `-q` and `-l` are accepted and ask for the
same ordered end, which has no orderly or immediate form, and whose log
line the coordinator writes for every end.

`halt` powers the machine off where FreeBSD's halts it without turning
it off: erXos has no end that halts without powering off. A board that
cannot turn itself off stays halted in its firmware.

Left out: `-c` (power cycle), `-d` (dump), `-k` (the next boot's kernel),
`-r` (reroot), `-n` and `-N` (sync), and the nextboot flags (`-D`, `-e`,
`-f`, `-o`, `-a`). erXos has no power cycle and no kernel dump on demand,
boots one image whose slot the update service chooses rather than a
kernel the command names, has no root file system to reroot, and has no
buffer cache for the command to sync. Each is a usage error.

Authority. Both commands need the `machine` facet, so a session whose
template holds no `machine` grant refuses them with the shell's
`no_facet` before they start. Every shell writes `reset\n` or `off\n` to
`/machine/ctl`: in a session the path reaches the session's grant, and
in the system domain's command shell the system domain's own grant, made
with the system principal (docs/design-shell.md, "Interfaces"). In a
session the command exits 0 once the end has begun; in the system shell,
which the end ends too, it waits for the end once the coordinator
accepted it, as FreeBSD's reboot waits for init, so the shell prints no
prompt over the end's last line. A refusal prints the errno's text, as
reboot(8)'s `err(1, NULL)` does, and exits 1.

The decisions are pure, parse/2, line/1 and accepted/1, and run/2 does
the effects.
""".
-behaviour(erx_cmd).

-erx_command(reboot).
-erx_usage("reboot [-lpq]").
-erx_needs([machine]).

-export([run/2]).
-export([parse/2, line/1, accepted/1]).
-export_type(['end'/0]).

-doc "The machine's end a command asks for: a reset or a power-off.".
-type 'end'() :: reset | off.

-define(CTL, <<"/machine/ctl">>).

-doc false.
run(Args, #{name := Name} = Ctx) ->
    case parse(Name, Args) of
        {ok, End} ->
            answer(write_ctl(erx_cmd:path(Ctx, ?CTL), line(End)), Ctx);
        {error, usage} = Usage ->
            Usage
    end.

-doc """
The end that command line Args asks for under command name Name, `reboot`
or `halt`, or a usage error for a flag this command does not take or an
argument after the flags, as getopt(3) and FreeBSD's command answer.
""".
-spec parse(binary(), [binary()]) -> {ok, 'end'()} | {error, usage}.
parse(Name, Args) ->
    case erx_cmd:getopt(Args, "lpq") of
        {ok, Flags, []} -> {ok, end_of(Name, lists:member($p, Flags))};
        _ -> {error, usage}
    end.

end_of(<<"halt">>, _PowerOff) -> off;
end_of(_Reboot, true) -> off;
end_of(_Reboot, false) -> reset.

-doc "The line a write to `/machine/ctl` asks for End with.".
-spec line('end'()) -> binary().
line(End) -> <<(atom_to_binary(End))/binary, $\n>>.

-doc """
What a command does once the coordinator accepted its end, in the system
domain (System true) or in any other runtime: the system shell, which the
end ends too, waits for it, as FreeBSD's reboot waits for init to end the
system, so the shell prints no prompt over the end's last line; a
session's command exits 0.
""".
-spec accepted(boolean()) -> wait | exit.
accepted(true) -> wait;
accepted(false) -> exit.

%% The effect: one write of Line to the ctl file.
write_ctl(Path, Line) ->
    case file:open(Path, [write, raw, binary]) of
        {ok, Fd} ->
            try file:write(Fd, Line) after file:close(Fd) end;
        {error, _} = Error ->
            Error
    end.

answer(ok, _Ctx) ->
    case accepted(erx_inspector:is_system_runtime()) of
        wait -> receive after infinity -> ok end;
        exit -> ok
    end;
answer({error, Reason}, #{name := Name} = Ctx) ->
    erx_cmd:say(Ctx, [Name, <<": ">>, erx_cmd:format_error(Reason), $\n]),
    {error, {reported, <<"1">>}}.
