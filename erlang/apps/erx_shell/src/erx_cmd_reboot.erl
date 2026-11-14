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
`no_facet` before they start. In a session the entry is the grant, and
the command writes `reset\n` or `off\n` to `/machine/ctl`, the tree the
grant mounts; in the system domain's command shell the entry is `local`,
and the command calls the coordinator's entry, erx_machine:request/2,
through the tree's erx_machine_fs:control/2, with the system principal,
so both routes answer the same errnos. In a session the command exits 0
once the end has begun; in the system shell, which the end ends too, it
waits for the end once the coordinator accepted it, as FreeBSD's reboot
waits for init, so the shell prints no prompt over the end's last line. A refusal prints the
errno's text, as reboot(8)'s `err(1, NULL)` does, and exits 1.

The decisions are pure, parse/2 and route/2, and run/2 does the
effects.
""".
-behaviour(erx_cmd).

-erx_command(reboot).
-erx_usage("reboot [-lpq]").
-erx_needs([machine]).

-export([run/2]).
-export([parse/2, route/2]).
-export_type(['end'/0]).

-doc "The machine's end a command asks for: a reset or a power-off.".
-type 'end'() :: reset | off.

-define(CTL, <<"/machine/ctl">>).

-doc false.
run(Args, #{name := Name} = Ctx) ->
    case parse(Name, Args) of
        {ok, End} ->
            {ok, Entry} = erx_cmd:facet(Ctx, machine),
            answer(act(route(Entry, End), Ctx), Ctx);
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

-doc """
How a command whose `machine` entry is Entry asks for End: in the system
domain's command shell, whose entry is `local`, through the coordinator's
entry, and anywhere else by writing the end's line to `/machine/ctl`.
""".
-spec route(local | term(), 'end'()) -> {local, 'end'()} | {write, binary(), binary()}.
route(local, End) -> {local, End};
route(_Grant, End) -> {write, ?CTL, <<(atom_to_binary(End))/binary, $\n>>}.

%% The effects: the coordinator's answer as the tree gives it, or the ctl write's.
act({local, End}, _Ctx) ->
    case erx_machine_fs:control(End, system) of
        ok -> wait_for_end();
        {error, _} = Refused -> Refused
    end;
act({write, Path, Line}, Ctx) ->
    case file:open(erx_cmd:path(Ctx, Path), [write, raw, binary]) of
        {ok, Fd} ->
            try file:write(Fd, Line) after file:close(Fd) end;
        {error, _} = Error ->
            Error
    end.

%% In the system domain the end ends this shell too, so once the coordinator accepted it
%% the command waits for it, as FreeBSD's reboot waits for init to end the system, and
%% the shell prints no prompt over the end's last line. It never returns.
wait_for_end() ->
    receive after infinity -> ok end.

answer(ok, _Ctx) ->
    ok;
answer({error, Reason}, #{name := Name} = Ctx) ->
    erx_cmd:say(Ctx, [Name, <<": ">>, erx_cmd:format_error(Reason), $\n]),
    {error, {reported, <<"1">>}}.
