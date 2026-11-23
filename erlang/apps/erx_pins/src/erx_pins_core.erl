%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The pin driver's decisions over one controller's table (docs/design-pinctrl.md, "At
%% start" and "States at run time"), pure: the settings a state or the start wants, which
%% pins a check leaves unset, the state a device reads as, the start's verdict for a
%% configuration and the system release's choice of configuration from its starts.
%%
%% A table is the controller's pins record as the pin driver reads it:
%%   #{kind := Module, rows := [Row], uses := #{Device => [normal | rescue]}}
%% Module is the kind's planner (erx_pins_bcm2711). A row is
%%   #{pin := Pin, owner := Device | gpio, state := State, setting := Setting}
%% with one row for each pin and state of a device, each state spelled out whole, and one
%% row in state default for each plain GPIO pin. The firmware's pins and reserved pins
%% have no row, so nothing planned from a table names them. uses gives, for each device
%% with default alone, the largest configuration that uses it: rescue, whose devices the
%% normal configuration uses too; normal, for a device only the normal configuration
%% uses; or none, for a device for no one.
-module(erx_pins_core).

-export([wanted/3, start_wanted/1, idle/0, unset/3, state_of/3, start_verdict/3,
         configuration/1]).

-export_type([table/0, verdict/0]).

-type device() :: non_neg_integer().
-type configuration() :: normal | rescue.
-type uses() :: configuration() | none.
-type table() :: #{kind := module(), rows := [map()], uses := #{device() => uses()}}.
%% One unset pin as a start's report names it.
-type unset() :: #{pin := non_neg_integer(), owner := device() | gpio, uses := uses(),
                   wanted := map(), read := map()}.
-type verdict() :: {ok, [unset()]} | {error, {unset, [unset()]}} | {error, {refused, term()}}.

%% A device's pins in a state, or enoent for a state the table does not give it.
-spec wanted(table(), device(), atom()) -> {ok, [{non_neg_integer(), map()}]} | {error, enoent}.
wanted(#{rows := Rows}, Device, State) ->
    case [{Pin, Setting} || #{pin := Pin, owner := Owner, state := S, setting := Setting} <- Rows,
                            Owner =:= Device, S =:= State] of
        [] -> {error, enoent};
        Pins -> {ok, Pins}
    end.

%% What every start of the pin driver plans: default for each device with default alone,
%% nothing for a device with other states, whatever it reads as, and each plain GPIO pin
%% idle.
-spec start_wanted(table()) -> [{non_neg_integer(), map()}].
start_wanted(#{rows := Rows} = Table) ->
    Single = [Device || Device <- devices(Table), states(Table, Device) =:= [default]],
    lists:sort([{Pin, Setting} || #{pin := Pin, owner := Owner, setting := Setting} <- Rows,
                                  lists:member(Owner, Single)] ++
               [{Pin, idle()} || #{pin := Pin, owner := gpio} <- Rows]).

%% A plain GPIO pin at rest: an input, no pull and no edge detection.
-spec idle() -> map().
idle() -> #{function => in, pull => none, edge => none}.

%% The check of an applied plan: the kind's plan again, over a new reading. A pin it names
%% in a step differs; every other wanted pin is set.
-spec unset(module(), map(), [{non_neg_integer(), map()}]) ->
          {ok, [non_neg_integer()]} | {error, {refused, term()}}.
unset(Kind, Read, Wanted) ->
    case Kind:plan(Read, Wanted) of
        {ok, Steps} -> {ok, lists:usort(lists:append([element(2, Step) || Step <- Steps]))};
        {error, Refusal} -> {error, {refused, Refusal}}
    end.

%% The one state of a device whose plan over the reading is empty, or unset.
-spec state_of(table(), device(), map()) -> atom().
state_of(#{kind := Kind} = Table, Device, Read) ->
    Agreeing = [State || State <- states(Table, Device),
                         begin {ok, Pins} = wanted(Table, Device, State),
                               Kind:plan(Read, Pins) =:= {ok, []} end],
    case Agreeing of
        [State] -> State;
        _ -> unset
    end.

%% The verdict of a start for a configuration, from the reading its check took: an error
%% when a pin it leaves unset is a device's that the configuration uses, or when the kind
%% refuses the plan. Every unset pin is in the report, whoever it is for; a device for no
%% one and a plain GPIO pin cost the report line alone.
-spec start_verdict(table(), configuration(), map()) -> verdict().
start_verdict(#{kind := Kind} = Table, Configuration, Read) ->
    Wanted = start_wanted(Table),
    case unset(Kind, Read, Wanted) of
        {error, _} = Refused ->
            Refused;
        {ok, Pins} ->
            Report = [report(Kind, Table, Read, Wanted, Pin) || Pin <- Pins],
            case [Entry || #{uses := Uses} = Entry <- Report, used_by(Uses, Configuration)] of
                [] -> {ok, Report};
                _ -> {error, {unset, Report}}
            end
    end.

%% Which configuration the system release boots, from its pin drivers' starts for the
%% normal one: normal when every start answered ok; rescue when what they left unset is
%% only what the normal configuration alone uses; none when a refused plan or a device
%% rescue uses leaves no configuration.
-spec configuration([verdict()]) -> configuration() | none.
configuration(Verdicts) ->
    case [Verdict || {error, _} = Verdict <- Verdicts] of
        [] -> normal;
        Failed ->
            case lists:all(fun rescue_can_boot/1, Failed) of
                true -> rescue;
                false -> none
            end
    end.

%% A failed start leaves rescue bootable only when it is no refusal and no pin it left
%% unset is a device's that rescue uses.
rescue_can_boot({error, {unset, Report}}) ->
    not lists:any(fun(#{uses := Uses}) -> Uses =:= rescue end, Report);
rescue_can_boot({error, {refused, _}}) ->
    false.

%% Whether a configuration uses a device of this uses value.
used_by(rescue, _Configuration) -> true;
used_by(normal, Configuration) -> Configuration =:= normal;
used_by(none, _Configuration) -> false.

%% A pin the start's plan wanted has rows of one owner. A device's uses value is the
%% table's, which has one for every device with default alone: a missing one fails the
%% start rather than reading as a device for no one.
report(Kind, #{rows := Rows, uses := Uses}, Read, Wanted, Pin) ->
    [Owner] = lists:usort([Owner || #{pin := P, owner := Owner} <- Rows, P =:= Pin]),
    Use = case Owner of
              gpio -> none;
              Device -> maps:get(Device, Uses)
          end,
    #{pin => Pin, owner => Owner, uses => Use,
      wanted => proplists:get_value(Pin, Wanted), read => Kind:setting(Read, Pin)}.

devices(#{rows := Rows}) -> lists:usort([Owner || #{owner := Owner} <- Rows, is_integer(Owner)]).

states(#{rows := Rows}, Device) ->
    lists:usort([State || #{owner := Owner, state := State} <- Rows, Owner =:= Device]).
