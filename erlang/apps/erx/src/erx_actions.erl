%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_actions).
-moduledoc """
The edge's one loop (docs/style.md, "Functional core"): it performs a core step's actions
in order, each through the edge's own effect, and ends at a stop, which a core puts last.

A stop with actions after it is the core's bug. The loop refuses it before performing any
action after it, with `error(stop_not_last)`: error/1's stack trace names this function's
arity, not its arguments, so the refusal carries neither the actions nor the edge's state.
An improper list is refused the same way, with `error(actions_not_a_list)`.
""".

-export([perform/3]).

-doc """
Performs `Actions` in order with `Effect`, which takes one action that is not a stop and the
edge's state and returns the next state. Returns `{continue, State}` when every action was
performed, or `{stop, Reason, State}` at the stop that ends them, with the state the actions
before it left.
""".
-spec perform([Action], fun((Action, State) -> State), State) ->
          {continue, State} | {stop, Reason :: term(), State}.
perform([{stop, Reason}], _Effect, State) -> {stop, Reason, State};
perform([{stop, _Reason} | _After], _Effect, _State) -> error(stop_not_last);
perform([Action | Actions], Effect, State) -> perform(Actions, Effect, Effect(Action, State));
perform([], _Effect, State) -> {continue, State};
perform(_NotAList, _Effect, _State) -> error(actions_not_a_list).
