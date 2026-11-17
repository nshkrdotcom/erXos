%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_service_sup).
-moduledoc """
The supervisor of a system service that the domain service mints facets in
front of: the log service, erx_syslog under erx_syslog_sup (docs/design-log.md,
"Service lifetime and restart"), and the clock service, erx_clock under
erx_clock_sup (docs/design-time.md, "Concurrency and failure").

Each names itself the server of its service's interface (erx_facet:serve/2),
so every facet of the service stands in front of the supervisor and outlives
the service's restarts, finding the service by its registered name at each
request (erx_log_facet, erx_clock_facet). It restarts the service at most
four times an hour, as kernel_safe_sup restarts its children, and past that
it ends, and with it every facet in front of it. Its parent holds it as a
`temporary` child (child_spec/1), so that end is neither restarted nor
counted there: a request that keeps crashing a service ends that service,
not its parent and with it the system domain.
""".
-behaviour(supervisor).

-export([child_spec/1, start_link/1, start_link/2]).
-export([init/1]).

-export_type([interface/0]).

-type interface() :: log | clock.

-doc """
The child spec of Interface's supervisor, as its parent, kernel_sup for log
and kernel_safe_sup for clock, lists it.
""".
-spec child_spec(interface()) -> supervisor:child_spec().
child_spec(Interface) ->
    {Name, _Service} = service(Interface),
    #{id => Name,
      start => {?MODULE, start_link, [Interface]},
      restart => temporary,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-doc """
Starts Interface's supervisor and its service in the runtime that serves it,
the system domain's; `ignore` in every other runtime, which serves neither.
""".
-spec start_link(interface()) -> supervisor:startlink_ret() | ignore.
start_link(Interface) ->
    case served_here(Interface) of
        true -> start_link(Interface, element(2, service(Interface)));
        false -> ignore
    end.

-doc """
Starts Interface's supervisor, under its registered name and the server of
Interface, of the one worker Service, started by Service:start_link/0.
start_link/1 runs it for the interface's own service; a test runs it for a
stand-in.
""".
-spec start_link(interface(), module()) -> supervisor:startlink_ret().
start_link(Interface, Service) ->
    {Name, _Service} = service(Interface),
    supervisor:start_link({local, Name}, ?MODULE, {Interface, Service}).

-doc false.
-spec init({interface(), module()}) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Interface, Service}) ->
    ok = erx_facet:serve(Interface, self()),
    {ok, {#{strategy => one_for_one, intensity => 4, period => 3600},
          [#{id => Service,
             start => {Service, start_link, []},
             restart => permanent,
             shutdown => 2000,
             type => worker,
             modules => [Service]}]}}.

%% Each interface's supervisor, by its registered name, and service.
service(log) -> {erx_syslog_sup, erx_syslog};
service(clock) -> {erx_clock_sup, erx_clock}.

%% The log is served in the system domain's runtime, the one whose `user` is
%% the system console (user_sup's rule); in every other domain erx_log_h sends
%% the records to the domain's proxy. The clock is served in the erXos runtime
%% whose boot page names the system domain's id and no system connection.
served_here(log) ->
    lists:member({user, ["erx_console"]}, init:get_arguments());
served_here(clock) ->
    erlang:system_info(os_type) =:= {unix, erxos} andalso erx_inspector:is_system_runtime().
