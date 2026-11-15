%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hold).
-moduledoc """
Who holds each pin, chip select and PWM channel of a header driver
(docs/design-header-io.md, "Holding and granting"): a pure core that the GPIO,
SPI and PWM drivers keep in their state. It decides whether an open succeeds,
when a resource is released, and whether an operation's handle is still live;
the driver performs what it answers in the same step, so the check and the
effect cannot be separated by another request.

**State.** A map from each held resource to its holder, a grant (the pid of the
grant's process, which runs the tree's `open/3`), and the holder's open handles
on it. A resource absent from the map is free. Only a holder gets handles, so a
handle still in the map is an open handle of its resource's current holder,
and every other handle is dead.

**Handles.** The core makes each handle at an open, from the core's
incarnation, the resource and a serial number that no earlier handle of the
core had. So a closed or ended handle never names a later hold of the same
resource, and a handle a grant kept across its driver's restart, or one of
another driver's core, is dead in a new core. A handle is opaque, so Dialyzer
refuses a driver that takes it apart instead of asking `operate/2`, the one
way from a handle to its resource. A handle is its grant's alone: the tree
keeps it in the grant's file and never hands it to another grant.

**Actions.** What the driver performs, in the order given:

    {release, R}     the hold on R ended: put R in its idle state
    {monitor, G}     G holds its first resource: monitor G, and hand the
                     monitor's down to ended/2
    {demonitor, G}   G's last handle closed: drop G's monitor, flushing it

A grant is monitored exactly while it holds a resource, so a grant that ends
without closing its handles still releases them, and a grant that closed them
all leaves no monitor behind.
""".

-export([new/1, open/3, close/2, ended/2, operate/2]).

-export_type([core/0, handle/0, grant/0, resource/0, action/0]).

-doc "The grant's process, which opens the files of its tree.".
-type grant() :: pid().

-doc "A pin, a chip select or a channel, as the driver names it.".
-type resource() :: term().

-doc "What the driver performs, as the moduledoc's table states it.".
-type action() :: {release, resource()}
                | {monitor, grant()}
                | {demonitor, grant()}.

-type serial() :: non_neg_integer().

-doc "An open of a resource's file, as the moduledoc's Handles states it.".
-opaque handle() :: {reference(), resource(), serial()}.

-record(hold, {holder :: grant(),
               handles :: ordsets:ordset(serial())}).

-record(core, {incarnation :: reference(),
               holds = #{} :: #{resource() => #hold{}},
               next = 0 :: serial()}).

-opaque core() :: #core{}.

-doc """
A driver's core before any open: every resource is free. Incarnation is a
reference the driver makes at its start, so no handle of an earlier core, or
of another driver's, is live in this one.
""".
-spec new(Incarnation :: reference()) -> core().
new(Incarnation) -> #core{incarnation = Incarnation}.

-doc """
An open of one of Resource's files by Grant. While another grant holds
Resource it answers `ebusy` and changes nothing; otherwise Grant holds
Resource and gets a new handle on it, with `{monitor, Grant}` when Grant held
nothing before.
""".
-spec open(grant(), resource(), core()) ->
          {ok, handle(), [action()], core()} | {error, ebusy}.
open(Grant, Resource, #core{incarnation = Incarnation, holds = Holds,
                            next = Serial} = Core) ->
    Handle = {Incarnation, Resource, Serial},
    case Holds of
        #{Resource := #hold{holder = Grant, handles = Handles} = Hold} ->
            Held = Hold#hold{handles = ordsets:add_element(Serial, Handles)},
            {ok, Handle, [],
             Core#core{holds = Holds#{Resource := Held}, next = Serial + 1}};
        #{Resource := _} ->
            {error, ebusy};
        #{} ->
            Held = #hold{holder = Grant, handles = [Serial]},
            Monitor = [{monitor, Grant} || not holds_any(Grant, Holds)],
            {ok, Handle, Monitor,
             Core#core{holds = Holds#{Resource => Held}, next = Serial + 1}}
    end.

-doc """
The close of a handle. Closing the holder's last handle on a resource
releases it, with `{demonitor, Grant}` when the holder then holds nothing. A
dead handle's close changes nothing.
""".
-spec close(handle(), core()) -> {[action()], core()}.
close({_, Resource, Serial} = Handle, #core{holds = Holds} = Core) ->
    case live(Handle, Core) of
        dead ->
            {[], Core};
        #hold{holder = Grant, handles = [Serial]} ->
            Left = maps:remove(Resource, Holds),
            Demonitor = [{demonitor, Grant} || not holds_any(Grant, Left)],
            {[{release, Resource} | Demonitor], Core#core{holds = Left}};
        #hold{handles = Handles} = Hold ->
            Fewer = Hold#hold{handles = ordsets:del_element(Serial, Handles)},
            {[], Core#core{holds = Holds#{Resource := Fewer}}}
    end.

-doc """
The end of Grant, from the down of its monitor: every resource it holds is
released, in resource order, and its handles die. The monitor has fired, so
there is nothing to demonitor.
""".
-spec ended(grant(), core()) -> {[action()], core()}.
ended(Grant, #core{holds = Holds} = Core) ->
    Released = lists:sort([R || R := #hold{holder = G} <- Holds, G =:= Grant]),
    {[{release, R} || R <- Released],
     Core#core{holds = maps:without(Released, Holds)}}.

-doc """
An operation by a handle: a `ctl` line, a `value` write, an `event` wait or
a transfer. It answers the resource to apply it to while the handle is an
open handle of the resource's current holder, and `eio` otherwise.
""".
-spec operate(handle(), core()) -> {ok, resource()} | {error, eio}.
operate({_, Resource, _} = Handle, Core) ->
    case live(Handle, Core) of
        #hold{} -> {ok, Resource};
        dead -> {error, eio}
    end.

%% The hold a handle is open on, or dead.
live({Incarnation, Resource, Serial},
     #core{incarnation = Incarnation, holds = Holds}) ->
    case Holds of
        #{Resource := #hold{handles = Handles} = Hold} ->
            case ordsets:is_element(Serial, Handles) of
                true -> Hold;
                false -> dead
            end;
        #{} ->
            dead
    end;
live(_, #core{}) ->
    dead.

holds_any(Grant, Holds) ->
    lists:any(fun(#hold{holder = G}) -> G =:= Grant end, maps:values(Holds)).
