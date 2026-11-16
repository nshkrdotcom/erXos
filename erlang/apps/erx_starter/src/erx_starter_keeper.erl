%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_keeper).
-moduledoc """
A keeper (docs/design-apps.md, "Keeping a session"): one process that
holds one session. It asks the domain service for its principal's session
with erx_domain:start_session/2, or for an app's with
erx_domain:start_app/2, of which keepers are the only callers (PK7), and
links to the session's domain pid. The link is both halves of the keeper's
contract:

* the session's end is the domain pid's end with {domain_down, Id, Info},
  which ends the keeper with that reason, so its supervisor counts it;
* the keeper's end, for any reason, a kill included, is an exit signal to
  the domain pid, which stops the domain (erx_domain_pid), so the session
  ends with its keeper and none outlives the row that kept it.

The keeper traps exits, so its supervisor's shutdown, which waits for it
without a bound, stops the session and returns only once the domain pid
has ended: a row's supervisor that has stopped holds no session, which a
publication that drops an app answers on (docs/design-packaging.md, PK7).

A start the service refuses ends the keeper with {shutdown, {refused,
Reason}}, an end its supervisor counts and proc_lib reports no crash for.

The start itself runs in a helper, which traps exits and links to the
keeper, so a keeper stopped while the service is still starting its
session leaves no session behind: the helper holds the new session by a
link of its own until the keeper has linked to it, and stops it if the
keeper ended first.

Start is what the table made: #{}, #{display => D} or
#{default_display => D}, D a service name the merge or the command check
found granted to the principal's template. The domain service takes the
name as the atom of a service it knows, so a name with no atom is no
service it serves and is refused without making one.
""".

-export([start_link/2]).
-export([keep/2]).

%% Whose session a keeper holds: a manifest principal's, by its number, or an app's, by
%% its name.
-type who() :: pos_integer() | {app, binary()}.

-spec start_link(who(), #{display => binary(), default_display => binary()}) -> {ok, pid()}.
start_link(Who, Start) ->
    {ok, proc_lib:spawn_link(?MODULE, keep, [Who, Start])}.

-doc false.
keep(Who, Start) ->
    process_flag(trap_exit, true),
    Keeper = self(),
    Helper = spawn_link(fun() -> start(Keeper, Who, Start) end),
    receive
        {Helper, {ok, Domain}} ->
            %% A session that ended before the keeper took it is an end too.
            Pid = erx_domain:pid(Domain),
            try link(Pid)
            catch error:noproc -> exit({shutdown, {ended, erx_domain:id(Domain)}})
            end,
            Helper ! {Keeper, taken},
            hold(Pid, Helper);
        {Helper, {error, Reason}} ->
            exit({shutdown, {refused, Reason}});
        {'EXIT', Helper, Reason} ->
            exit(Reason);
        {'EXIT', _Supervisor, Reason} ->
            %% Stopped while the start runs: the helper takes the keeper's exit signal as
            %% the keeper's end, stops the session the start makes and ends once that
            %% session has ended, so the keeper ends only then too. The keeper has not
            %% ended yet, so it sends the signal itself before it waits.
            exit(Helper, Reason),
            receive {'EXIT', Helper, _} -> exit(Reason) end
    end.

%% The session held: its end is the keeper's, and the keeper's stop by its supervisor
%% stops the session and ends only once the session has ended. The keeper's links are
%% its supervisor, the helper, which ends normally once the keeper took the session, and
%% the domain pid.
hold(Pid, Helper) ->
    receive
        {'EXIT', Pid, Reason} ->
            exit(Reason);
        {'EXIT', Helper, normal} ->
            hold(Pid, Helper);
        {'EXIT', _Supervisor, Reason} ->
            Monitor = monitor(process, Pid),
            exit(Pid, Reason),
            receive {'DOWN', Monitor, process, Pid, _} -> exit(Reason) end
    end.

%% The helper: the start, held by a link until the keeper takes it.
start(Keeper, Who, Start) ->
    process_flag(trap_exit, true),
    case start_session(Who, Start) of
        {ok, Domain} = Started ->
            Pid = erx_domain:pid(Domain),
            link(Pid),
            Keeper ! {self(), Started},
            receive
                {Keeper, taken} -> unlink(Pid);
                {'EXIT', Keeper, _} ->
                    Monitor = monitor(process, Pid),
                    exit(Pid, abandoned),
                    receive {'DOWN', Monitor, process, Pid, _} -> exit(abandoned) end
            end;
        {error, _} = Refused ->
            Keeper ! {self(), Refused}
    end.

start_session(Who, Start) ->
    try do_start(Who, maps:map(fun(_Key, Name) -> binary_to_existing_atom(Name) end, Start))
    catch
        error:badarg -> {error, no_service};
        exit:{Reason, {gen_server, call, _}} -> {error, Reason}
    end.

do_start({app, Name}, Start) -> erx_domain:start_app(Name, Start);
do_start(Principal, Start) -> erx_domain:start_session(Principal, Start).
