%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The edge's one loop, erx_core:perform/3 (docs/style.md, "Functional core").
-module(erx_core_tests).

-include_lib("eunit/include/eunit.hrl").

%% The effect of these cases: each action is recorded, newest first.
effect(Action, Done) -> [Action | Done].

actions_are_performed_in_order_test() ->
    ?assertEqual({continue, [b, a]}, erx_core:perform([a, b], fun effect/2, [])),
    ?assertEqual({continue, []}, erx_core:perform([], fun effect/2, [])).

a_stop_ends_with_the_state_before_it_test() ->
    ?assertEqual({stop, ended, [b, a]}, erx_core:perform([a, b, {stop, ended}], fun effect/2, [])).

%% A stop with an action after it is refused before the action is performed, here one that
%% would raise, and the refusal's stack trace names the loop's arity, not the bytes of the
%% state it was passed.
a_stop_not_last_is_refused_test() ->
    Secret = <<"SECRET-STATE">>,
    Raise = fun(_Action, _State) -> error(performed) end,
    try erx_core:perform([{stop, ended}, write], Raise, Secret) of
        Result -> error({performed, Result})
    catch
        error:stop_not_last:Stack ->
            ?assertMatch([{erx_core, perform, 3, _} | _], Stack),
            ?assertEqual(nomatch, binary:match(term_to_binary(Stack), Secret))
    end.
