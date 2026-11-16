%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(erx_sdk_boundary).
-moduledoc """
The SDK's boundary check (docs/design-packaging.md, "Examples" and
"Verification and testing", the SDK's boundary): every call an app's
compiled modules make outside themselves and outside stock OTP is one of
the SDK's public functions, by module, function and arity.

outside/2 analyses the beams of the app's ebin directories with xref and
answers `{Outside, Variable}`. Outside is the calls that break the rule,
`{Caller, Callee}` pairs of `{Module, Function, Arity}`, sorted; `[]`
when the app keeps to the SDK. Variable is the calls whose callee xref
cannot name, through a variable module, a fun in a variable or apply/3,
each with the callee's module `'$M_EXPR'` (and its function
`'$F_EXPR'` where that is a variable too), sorted. The check cannot say
where such a call goes, so its caller pins Variable to the list of calls
it has reviewed, and a call it has not fails.
A module of the app whose name already loads, from stock OTP or the SDK,
fails the check, since the image's module of that name is the one that
runs. A callee is stock OTP's when its module loads from below
code:lib_dir() or is preloaded and exports it, which holds for the host's stock OTP 29.1.2 with the
SDK's applications on the path beside it, not inside it.
xref reads a beam's calls from its debug information, so a beam compiled
without `debug_info` fails the check instead of passing unread.
""".

-export([outside/2]).

-doc """
The calls of the modules in `Ebins` that leave the app and stock OTP for a
function `Public`, the SDK's erlang/public.txt, does not list, and apart
from them the calls whose callee xref cannot name.
""".
-spec outside([file:filename()], file:filename()) -> {[{mfa(), mfa()}], [{mfa(), mfa()}]}.
outside(Ebins, Public) ->
    Listed = public(Public),
    {ok, Xref} = xref:start([{xref_mode, functions}]),
    try
        ok = xref:set_default(Xref, [{warnings, false}, {verbose, false}]),
        Own = lists:append([added(Xref, Ebin) || Ebin <- Ebins]),
        [error({shadows, Module}) || Module <- Own, code:which(Module) =/= non_existing],
        {ok, Calls} = xref:q(Xref, "E"),
        {Variable, Named} = lists:partition(fun({_Caller, {Module, _, _}}) -> Module =:= '$M_EXPR' end, Calls),
        {lists:sort([Call || {{From, _, _}, {Module, _, _} = Callee} = Call <- Named,
                             Module =/= From,
                             not lists:member(Module, Own),
                             not stock(Callee),
                             not sets:is_element(Callee, Listed)]),
         lists:sort(Variable)}
    after
        xref:stop(Xref)
    end.

%% The modules of Ebin, every one of which xref must take: a beam without
%% debug information it skips, and a check that skipped one would pass it.
added(Xref, Ebin) ->
    {ok, Modules} = xref:add_directory(Xref, Ebin),
    Beams = [list_to_atom(filename:basename(Beam, ".beam"))
             || Beam <- filelib:wildcard("*.beam", Ebin)],
    case Beams -- Modules of
        [] -> Modules;
        Skipped -> error({no_debug_info, Ebin, Skipped})
    end.

%% public.txt's lines, MODULE:FUNCTION/ARITY each, as a set of mfa().
public(File) ->
    {ok, Text} = file:read_file(File),
    sets:from_list([mfa(Line) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])]).

mfa(Line) ->
    [Module, Function, Arity] = binary:split(Line, [<<":">>, <<"/">>], [global]),
    {binary_to_atom(Module), binary_to_atom(Function), binary_to_integer(Arity)}.

%% A function stock OTP gives: its module loads from below code:lib_dir() or
%% is preloaded, and exports it there, so a function erXos adds to a module
%% of a stock name (prim_file's erx_* calls) is not stock.
stock({Module, Function, Arity}) ->
    Stock = case code:which(Module) of
                preloaded -> true;
                Path when is_list(Path) -> lists:prefix(code:lib_dir() ++ "/", Path);
                _NonExistingOrCover -> false
            end,
    Stock andalso code:ensure_loaded(Module) =:= {module, Module}
        andalso (erlang:function_exported(Module, Function, Arity)
                 orelse erlang:is_builtin(Module, Function, Arity)).
