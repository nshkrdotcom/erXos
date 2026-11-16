%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_query).
-moduledoc """
Queries of a widget tree for a desktop program's core tests
(docs/design-desktop-programs.md, "The construction"): input/4 finds the
one node a query matches and answers the input the widget server would
send when a person acts on it, so a test reads "click Back" and never
indexes a tree by position.

A query names a node by what a person or an assistive reader perceives of
it: its kind, its text, its role or its `name`, each matched exactly. A
query that matches no node, or several, is refused.

input/4 realises the tree as the widget server does, erx_ui_schema's
validation and then erx_ui_model:pair/3 on an empty tree, reads each
node's number and properties from the model's own inserts
(erx_ui_model:delta/2 from the empty tree), and checks the action with
erx_ui_model:hit/4, the server's own check of a renderer's report. So it
answers the server's `{ui, Window, Term, Detail}` and refuses an action
the server would drop. It also refuses an action on a node that is
disabled, hidden or under a hidden node, since no renderer reports one
there. Every refusal is an error naming the query.
""".

-export([input/4]).
-export_type([query/0, action/0]).

-doc "What a node is found by; every key given must match.".
-type query() :: #{kind => atom(), text => term(), role => atom(), name => binary()}.
-doc "What a person does to a node, as the renderer reports it.".
-type action() :: click | select | {change, Value :: term()} | {submit, Value :: term()}.

%% The node quota erx_ui_server validates a tree under (erx_ui_server.erl, UI_NODES).
-define(UI_NODES, 10000).

-doc """
The input the widget server sends window `Window` when a person does
`Action` to the one node of `Tree` that `Query` matches.
""".
-spec input(Window :: term(), query(), action(), erx_ui_model:tree()) ->
          {ui, Window :: term(), Term :: term(), Detail :: term()}.
input(Window, Query, Action, Tree) ->
    case erx_ui_schema:validate(Tree, ?UI_NODES) of
        ok -> ok;
        {error, Reason} -> error({invalid_tree, Reason})
    end,
    {Ui, _Next} = erx_ui_model:pair(erx_ui_model:empty(), Tree, 1),
    Number = case the_one(Query, realised_nodes(Ui)) of
                 #{number := N, actable := true} -> N;
                 #{actable := false} -> error({cannot_act, Query})
             end,
    {Event, Value} = event(Action),
    case erx_ui_model:hit(Ui, Number, Event, Value) of
        {fire, Term, Detail, _Ui1} -> {ui, Window, Term, Detail};
        _KeptOrDropped -> error({no_event, Query, Action})
    end.

%% The node event an action reports, and the state value it carries.
event(click) -> {on_click, none};
event(select) -> {on_select, none};
event({change, Value}) -> {on_change, Value};
event({submit, Value}) -> {on_submit, Value}.

the_one(Query, Nodes) ->
    case maps:keys(Query) -- [kind, text, role, name] of
        [] -> ok;
        Unknown -> error({bad_query, Query, Unknown})
    end,
    case [Node || Node <- Nodes, matches(Query, Node)] of
        [One] -> One;
        [] -> error({no_node, Query});
        Several -> error({several_nodes, Query, length(Several)})
    end.

matches(Query, #{kind := Kind, props := Props}) ->
    maps:fold(fun(kind, Wanted, Acc) -> Acc andalso Wanted =:= Kind;
                 (Key, Wanted, Acc) -> Acc andalso maps:find(Key, Props) =:= {ok, Wanted}
              end, true, Query).

%% Every node of realised tree Ui, from the inserts that build it from the
%% empty tree, which come parent first: its number, kind and properties,
%% and whether a person can act on it, which needs it and every node
%% above it shown and it enabled.
realised_nodes(Ui) ->
    Empty = erx_ui_model:empty(),
    Inserts = [{Id, Parent, Kind, Props}
               || {insert, Id, Parent, _Index, Kind, Props} <- erx_ui_model:delta(Empty, Ui)],
    {Nodes, _Shown} = lists:mapfoldl(fun node_of/2, #{0 => true}, Inserts),
    Nodes.

node_of({Id, Parent, Kind, Props}, Shown) ->
    IsShown = maps:get(Parent, Shown) andalso maps:get(visible, Props, true),
    {#{number => Id, kind => Kind, props => Props,
       actable => IsShown andalso maps:get(enabled, Props, true)},
     Shown#{Id => IsShown}}.
