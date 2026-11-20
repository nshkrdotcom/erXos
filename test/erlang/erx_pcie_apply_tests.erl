%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_pcie_apply, the planner's effect layer (docs/design-pcie.md,
%% "Applying a plan" and "Host tests of the pure cores"), over erx_pcie_model as the
%% bridge driver. Each plan of the planner's inputs, erx_pcie_plan_tests' endpoint and
%% root port with that module's oracle, is run once with every write taking, once with
%% each of its writes ignored alone (a later write of the same register then repeating
%% it), and once with each register ignoring every write from one write on. Of each run:
%%
%% * data_while_quiet: no write that would move data is made while the model is not
%%   quiet;
%% * raised_while_data_differ: no write that would raise a switch is made while a data
%%   field of the model differs from the target;
%% * the answer: ok only when the model reads as the target, {error, gone} only when it
%%   reads quiet, {error, stuck} only when it does not, and ok whenever every write
%%   takes; a planner's refusal before any write;
%% * only_the_descent: the plan's stages are written in order, and after a stage the
%%   model does not read as, the only writes are the descent to quiet from what it reads.
%%   This property alone takes its stages, readbacks and descent from erx_pcie_plan, so
%%   it checks the effect layer's sequencing against the planner; the other three judge
%%   the model by erx_pcie_plan_tests' own decoding of its registers.
%%
%% A case gathers every property it finds broken over all its runs, so a seeded fault
%% names each property it breaks.
%%
%% The endpoint runs over every switch state, mode and route, with its data all equal or
%% all differing, for an MSI form without per-vector masking and one with it, each with
%% and without MSI-X: every write the planner makes, each register alone, at a cost the
%% landing gate can carry. The planner's own cases cover the rest of its inputs.
-module(erx_pcie_apply_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erx_pcie_plan_tests, [endpoint/4, layout/2, message/0, switch_states/2, data_fields/1,
                              root_port/2, root_target/1, parsed/1, made/2, levels/1, data_view/1,
                              data_ok/2, reads_as/2]).

-export([access/2]).

-define(PLACE, {0, 1, 0}).
-define(DEADLINE, 300).

%% --- The driver ------------------------------------------------------------------

%% The model reached through its ECAM window, each write issued kept with the snapshot
%% the model held when it was made: {Table, [{Before, Write}]}, newest first. Only
%% access/2 of erx_pcie_bridge is reached here.

access({read, Place, Offset, Width}, {Table, _Issued} = State) ->
    {{ok, erx_pcie_model:read({Table, 0}, ecam(Place) + Offset, Width)}, State};
access({write, Place, Offset, Width, Value}, {Table, Issued}) ->
    Before = erx_pcie_model:snapshot(Table, Place),
    ok = erx_pcie_model:write({Table, 0}, ecam(Place) + Offset, Width, Value),
    {ok, {Table, [{Before, {Offset, Width, Value}} | Issued]}}.

ecam({Bus, Device, Function}) -> (Bus bsl 20) bor (Device bsl 15) bor (Function bsl 12).

%% One run of Target from Snapshot under the model's ignore rule: the answer, the
%% writes issued oldest first, each with the model before it, and the model after.
run(Snapshot, Target, Rule) ->
    Table = erx_pcie_model:new([{?PLACE, Snapshot, #{}}]),
    erx_pcie_model:ignore(Table, Rule),
    {Result, {?MODULE, {Table, Issued}}} = erx_pcie_apply:apply(?PLACE, Target, {?MODULE, {Table, []}}),
    Final = erx_pcie_model:snapshot(Table, ?PLACE),
    ets:delete(Table),
    {Result, lists:reverse(Issued), Final}.

%% --- The properties --------------------------------------------------------------

%% The properties broken over every run of every input, each with its first example.
broken(Inputs) ->
    lists:foldl(fun({Snapshot, Target}, Broken) -> input(Snapshot, Target, Broken) end, #{}, Inputs).

input(Snapshot, Target, Broken) ->
    case erx_pcie_plan:plan(parsed(Snapshot), Target) of
        {error, _} = Refused ->
            {Result, Issued, _} = run(Snapshot, Target, none),
            note(Result =:= Refused andalso Issued =:= [], refused_before_any_write, {none, Target}, Broken);
        {ok, Stages} ->
            {_, Clean, _} = Taken = run(Snapshot, Target, none),
            Rules = [none] ++ [Rule || N <- lists:seq(1, length(Clean)), Rule <- [{once, N}, {from, N}]],
            lists:foldl(fun(Rule, B) ->
                                Ran = case Rule of
                                          none -> Taken;
                                          _ -> run(Snapshot, Target, Rule)
                                      end,
                                properties(Stages, Target, Ran, {Rule, Target}, B)
                        end, Broken, Rules)
    end.

properties(Stages, Target, {Result, Issued, Final}, {Rule, _} = Example, Broken) ->
    Checks = [{data_while_quiet,
               lists:all(fun({Before, Write}) -> not moves_data(Before, Write) orelse quiet(parsed(Before)) end,
                         Issued)},
              {raised_while_data_differ,
               lists:all(fun({Before, Write}) -> not raises(Before, Write) orelse data_ok(parsed(Before), Target) end,
                         Issued)},
              {answer, answer(Result, parsed(Final), Target, Rule)},
              {only_the_descent, follows(Stages, Issued, Final)}],
    lists:foldl(fun({Property, Holds}, B) -> note(Holds, Property, Example, B) end, Broken, Checks).

note(true, _Property, _Example, Broken) -> Broken;
note(false, Property, Example, Broken) -> maps:merge(#{Property => Example}, Broken).

%% Whether Write, made to the model as it was Before, would move a data field or
%% raise a switch.
moves_data(Before, Write) -> data_view(parsed(Before)) =/= data_view(parsed(made(Before, Write))).

raises(Before, Write) ->
    {From, To} = {levels(parsed(Before)), levels(parsed(made(Before, Write)))},
    lists:any(fun(Switch) -> maps:get(Switch, To) > maps:get(Switch, From) end, maps:keys(To)).

quiet(Read) -> lists:all(fun(Level) -> Level =:= 0 end, maps:values(levels(Read))).

answer(ok, Final, Target, _Rule) -> reads_as(Final, Target);
answer({error, gone}, Final, _Target, Rule) -> Rule =/= none andalso quiet(Final);
answer({error, stuck}, Final, _Target, Rule) -> Rule =/= none andalso not quiet(Final);
answer(_Other, _Final, _Target, _Rule) -> false.

%% The stages' writes in order; after a stage the model does not read as, the writes
%% that remain are the descent to quiet from the model as it then reads.
follows([], Rest, _Final) ->
    Rest =:= [];
follows([#{writes := Writes, state := State} | Stages], Issued, Final) ->
    {Made, Rest} = lists:split(min(length(Writes), length(Issued)), Issued),
    After = case Rest of
                [{Next, _} | _] -> Next;
                [] -> Final
            end,
    [Write || {_, Write} <- Made] =:= Writes
        andalso case erx_pcie_plan:differs(parsed(After), State) of
                    none ->
                        follows(Stages, Rest, Final);
                    _ ->
                        {ok, Descent} = erx_pcie_plan:quiet(parsed(After)),
                        [Write || {_, Write} <- Rest] =:= lists:append([Ws || #{writes := Ws} <- Descent])
                end.

%% --- The inputs ------------------------------------------------------------------

%% The effect layer logs each write that did not take, which these runs make by the
%% thousand; the cases run with the log at errors alone.
quietly(Tests) ->
    {setup,
     fun() ->
             #{level := Level} = logger:get_primary_config(),
             ok = logger:set_primary_config(level, error),
             Level
     end,
     fun(Level) -> logger:set_primary_config(level, Level) end,
     Tests}.

endpoint_test_() ->
    quietly([{timeout, ?DEADLINE, {lists:flatten(io_lib:format("apply endpoint ~p msix ~p", [Msi, Msix])),
                           fun() -> ?assertEqual(#{}, broken(endpoint_inputs(Msi, Msix))) end}}
     || Msi <- [msi32, msi64_mask], Msix <- [false, true]]).

endpoint_inputs(Msi, Msix) ->
    Layout = layout(Msi, Msix),
    [{endpoint(Msi, Msix, Levels, Differing), {function, Layout, #{mode => Mode, route => Route, message => message()}}}
     || Levels <- switch_states(true, Msix),
        Differing <- [[], data_fields(Msi)],
        Mode <- [off, decoding, mastering],
        Route <- [none, msi, msix, intx]].

root_port_test_() ->
    quietly({timeout, ?DEADLINE,
     {"apply root port",
      fun() ->
              Groups = [buses, io, memory, prefetch],
              ?assertEqual(#{}, broken([{root_port(Levels, Differing), {root_port, root_target(Window)}}
                                         || Levels <- switch_states(true, false),
                                            Differing <- [[], Groups],
                                            Window <- [closed, {16#10000000, 16#101fffff}]]))
      end}}).
