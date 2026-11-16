%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_uart_sup).
-moduledoc """
The system domain's UARTs that the console does not drive: the host link's
and the line trees' (docs/design-shared-devices.md, "Lines inside a
domain"; docs/design-bluetooth.md, "The shared line 153").

`erx_uart_sup` is `one_for_one` over **line groups**, one for each
interrupt line those UARTs use, so a line has one binder whichever services
drive it, and a failure on one line restarts nothing on another. A group is
a `rest_for_one` supervisor of, in order:

1. the line's owner, when the line is shared, which erx_irq_line:owners/1
   computes from the records of the group's UARTs;
2. the line's services, a `one_for_one` supervisor of the host link
   (erx_hostlink), when its UART is on the line, and the line tree of each
   line UART on it (erx_line), which starts its own driver, erx_pl011
   started fresh from the record.

So an owner's end restarts exactly the services on its line, a new owner
binds the line before any driver joins it, and one service's failure
restarts no other. The UARTs are the root's device records of role
`hostlink` and `line` (erx_device_record): the root writes the host link's
when the boot asks for the host link and the line's for the UART the line
grant's `uart` names, at most one of each. A machine with neither starts no
group.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/0, groups/1, line_grants/1]).
-export([init/1]).

-export_type([member/0]).

%% A UART a group starts a service on: the host link's, or a line tree's.
-type member() :: {hostlink | line, erx_device_record:spec()}.

-doc "Starts the line groups of the root's host link and line records.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

-doc """
The line groups of Members, in the order their lines first appear, each its
line's number and its members, the host link's before the line trees'. A
record's line is its one interrupt line, whether it is marked shared or
direct, so two members on one line are always one group. Pure.
""".
-spec groups([member()]) -> [{non_neg_integer(), [member()]}].
groups(Members) ->
    [{Line, on(Line, hostlink, Members) ++ on(Line, line, Members)}
     || Line <- lists:uniq([line(Spec) || {_Role, Spec} <- Members])].

on(Line, Role, Members) ->
    [Member || {R, Spec} = Member <- Members, R =:= Role, line(Spec) =:= Line].

-doc false.
init(top) ->
    case members() of
        {ok, Members} ->
            {ok, {#{strategy => one_for_one, intensity => 3, period => 60},
                  [group(Line, Group) || {Line, Group} <- groups(Members)]}};
        {error, Reason} ->
            {stop, Reason}
    end;
init({group, Members}) ->
    Owners = erx_irq_line:owners([{erx_pl011, [Spec || {_Role, Spec} <- Members]}]),
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 60},
          [owner(Spec, Index) || {Spec, Index} <- Owners] ++ [services(Members)]}};
init({services, Members}) ->
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [service(Member) || Member <- Members]}}.

%% The host link's record and the line's, each at most one.
members() ->
    maybe
        {ok, Hostlink} ?= one(hostlink),
        {ok, Line} ?= one(line),
        {ok, Grants} ?= configured_grants(Line),
        {ok, [{hostlink, Spec} || Spec <- Hostlink] ++ [{line, fresh(Spec, Grants)} || Spec <- Line]}
    end.

%% The system manifest's line grants (line_grants/1), when the root wrote a line record.
configured_grants([]) ->
    {ok, #{}};
configured_grants(_Line) ->
    maybe
        {ok, Configured} ?= erx_domain_lib:configured(),
        {ok, line_grants(Configured)}
    end.

%% A line record as erx_pl011 starts it fresh, with the rate and the flow of the grant
%% whose uart is the record's device row, the one row the root wrote the record for.
fresh(#{index := Index} = Spec, Grants) ->
    #{Index := #{rate := Rate, flow := Flow}} = Grants,
    Spec#{init => fresh, rate => Rate, flow => flow(Flow)}.

flow(<<"none">>) -> none;
flow(<<"rts_cts">>) -> rts_cts.

-doc """
The grants of Configured, what erx_domain_lib:configured/0 reads of the
system manifest, of each service the system domain serves of the line
interface, whatever the manifest names it, by the device row their uart
names. Pure.
""".
-spec line_grants(#{services := [{non_neg_integer() | system, atom(), non_neg_integer()}],
                    grants := [{term(), atom(), non_neg_integer() | system, map()}], atom() => term()}) ->
          #{non_neg_integer() => map()}.
line_grants(#{services := Services, grants := Grants}) ->
    Lines = [Name || {system, Name, ?ERX_SERVICE_LINE} <- Services],
    #{Uart => Grant || {_Grantee, Name, system, #{uart := Uart} = Grant} <- Grants, lists:member(Name, Lines)}.

one(Role) ->
    case erx_device_record:find(Role, pl011) of
        {ok, [_, _ | _]} -> {error, {Role, "more than one device record of role " ++ atom_to_list(Role)}};
        Found -> Found
    end.

%% A record's one interrupt line, the receive line erx_pl011 attaches.
line(#{lines := [{shared, Line}]}) -> Line;
line(#{lines := [Line]}) when is_integer(Line) -> Line.

group(Line, Members) ->
    #{id => {line, Line},
      start => {supervisor, start_link, [?MODULE, {group, Members}]},
      restart => permanent,
      type => supervisor}.

services(Members) ->
    #{id => services,
      start => {supervisor, start_link, [?MODULE, {services, Members}]},
      restart => permanent,
      type => supervisor}.

owner(Spec, Index) ->
    #{id => owner,
      start => {erx_irq_line, start_owner, [Spec, Index]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [erx_irq_line]}.

service({hostlink, Spec}) ->
    #{id => hostlink,
      start => {erx_hostlink, start_link, [Spec]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [erx_hostlink]};
service({line, Spec}) ->
    #{id => {line_tree, maps:get(path, Spec)},
      start => {erx_line, start_link, [fun(Line) -> erx_pl011:start_link(Spec, Line) end]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [erx_line]}.
