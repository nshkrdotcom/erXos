%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk).
-moduledoc """
The desktop programs' entry (docs/design-desktop-programs.md, "Shipping
and starting" and "The construction"). A program is named by an atom,
`clock`, whose core is the module `erx_desk_<name>_core`; a name with no
such module is `badarg`. Names come from the commands and the session's
shell, already atoms, so each makes at most one more.

open/2 opens one more window of a program; nothing is single-instance.
reload/1, called at the session's Erlang shell after a new core is
loaded, has every open window of that program hand the tree the new
core's view/1 makes of the state the window holds.
""".

-export([open/1, open/2, reload/1]).

-doc "Opens a window of program Name with no arguments.".
-spec open(atom()) -> ok | {error, term()}.
open(Name) ->
    open(Name, #{}).

-doc """
Opens a window of program Name, its core started with Args, answering
once its UI is open: `ok`, or the toolkit's `{error, Reason}`, such as
`{error, no_display}`.
""".
-spec open(atom(), term()) -> ok | {error, term()}.
open(Name, Args) ->
    case erx_desk_sup:start_window(#{core => core(Name), args => Args, label => atom_to_binary(Name)}) of
        {ok, _Window} -> ok;
        {error, _Reason} = Refused -> Refused
    end.

-doc "Has every open window of program Name present its core's newest view.".
-spec reload(atom()) -> ok.
reload(Name) ->
    Core = core(Name),
    lists:foreach(fun(Window) -> Window ! {erx_desk, reload, Core} end, erx_desk_sup:windows()).

core(Name) when is_atom(Name) ->
    Core = binary_to_atom(<<"erx_desk_", (atom_to_binary(Name))/binary, "_core">>),
    case code:ensure_loaded(Core) of
        {module, Core} -> Core;
        {error, _Why} -> error(badarg, [Name])
    end.
