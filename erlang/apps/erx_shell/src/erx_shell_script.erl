%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_script).
-moduledoc """
Runs rc's language with real commands: a source evaluated by
erx_shell_eval over erx_shell_runner, with the command namespace of the
shell's release (docs/design-shell.md). The interactive layer reads lines
and calls the same evaluator; this module runs a whole source, a line
typed at the Erlang shell or a script, and gives how it ended.

The evaluator runs in a process of its own with a heap limit, so a
runaway script ends that process and never its caller (SH2). The
context it hands commands holds the session's facets, those of the
domain the shell runs in (erx_shell_runner:facets/0), read for each command, so a
command that declares a facet the session lacks fails with `no_facet` before
it starts, and one installed while the script runs serves the next command.
""".

-export([run/1, run/2, script/1, command/2, first_vars/1, main/1]).

-export_type([options/0, vars/0, ending/0]).

-type options() :: #{cwd => binary(),
                     fds => #{erx_shell_lex:fd() => erx_cmd:stream()},
                     vars => vars(),
                     applications => [atom()]}.
%% Variables, each name with its value, a list of words.
-type vars() :: #{binary() => erx_shell_eval:value()}.
%% How a source ended, with the final `$status`: it ran to its end, ran
%% `exit`, stopped on a fault of the language or did not parse.
-type ending() :: {ok | exit | fault | syntax_error, Status :: binary()}.

-define(MAX_HEAP_WORDS, 32 bsl 20).
%% The longest value, all its words together, of a first variable (first_vars/1).
-define(MAX_FIRST_VALUE, 256).

-doc "Runs a source at the terminal, from `/`.".
-spec run(iodata()) -> ending().
run(Source) -> run(Source, #{}).

-doc """
Runs a source with the given working directory (`/`), descriptors (0 at
end of input, 1 and 2 the terminal), variables and command releases (the
command shell's own).
""".
-spec run(iodata(), options()) -> ending().
run(Source, Options) ->
    {_Pid, Ref} = spawn_opt(evaluation(iolist_to_binary(Source), shell(Options)), [monitor, heap_limit()]),
    receive {'DOWN', Ref, process, _, Reason} -> ending_of(Reason) end.

%% The evaluator's shell for Options, at the calling process's terminal.
shell(Options) ->
    Leader = group_leader(),
    Terminal = {tty, fun(Bytes) -> file:write(Leader, Bytes) end},
    Fds = maps:get(fds, Options, #{0 => null, 1 => Terminal, 2 => Terminal}),
    {Table, _Problems} = erx_shell_namespace:from_applications(
                           maps:get(applications, Options, [erx_shell])),
    State = erx_shell_runner:state(#{cwd => maps:get(cwd, Options, <<"/">>), fds => Fds,
                                   table => Table, facets => fun erx_shell_runner:facets/0}),
    Vars = maps:merge(#{<<"home">> => [<<"/">>], <<"*">> => []}, maps:get(vars, Options, #{})),
    erx_shell_eval:new(Vars, erx_shell_runner:runner(), State).

-doc "Runs the rc script at Path, at the terminal.".
-spec script(file:name_all()) -> ending() | {error, file:posix()}.
script(Path) ->
    case file:read_file(Path) of
        {ok, Source} -> run(Source, #{vars => #{<<"0">> => [iolist_to_binary(Path)]}});
        {error, Reason} -> {error, Reason}
    end.

-doc """
Starts rc on Command at the terminal, as `rc -c Command` runs as a program
(docs/design-shell.md, "rc as a program"): a group's shell for a tty that runs
one command (erx_session_tty:open_channel/3), with the first variables Vars
(first_vars/1), which ends with the command's exit status as the command
shell does at its end (erx_shell:exit_with/1).

The command runs as one job under a job leader of its own (erx_shell_leader),
so every process it starts, pipeline stages, subshells and backquotes, ends
with it: Ctrl-C, which the group sends this process as the exit signal
`interrupt`, ends them all and the command with status 130, 128 and SIGINT,
as FreeBSD's sh reports a command SIGINT ended; any other exit signal from
the group, as at the tty's hangup, ends them and this process for the same
reason; and the leader ends what it leads whenever this process ends. An exit
signal from any other process is a message left unread. Exits are trapped
before the leader and the evaluator start, so an interrupt that comes sooner
ends this process with nothing started.
""".
-spec command(binary(), vars()) -> pid().
command(Command, Vars) when is_binary(Command) ->
    proc_lib:spawn_link(fun() -> exec(Command, Vars) end).

exec(Command, Vars) ->
    process_flag(trap_exit, true),
    Group = group_leader(),
    Shell = shell(#{vars => first_vars(Vars)}),
    Leader = erx_shell_leader:start(Group),
    {_Pid, Ref, Go} = erx_shell_leader:spawn_member(Leader, evaluation(Command, Shell), [heap_limit()]),
    ok = Go(),
    {_Ending, Status} =
        receive
            {'DOWN', Ref, process, _, Reason} ->
                ending_of(Reason);
            {'EXIT', Group, Signal} ->
                ok = erx_shell_leader:release(kill, Leader),
                signalled(Signal)
        end,
    erx_shell:exit_with(Status).

-doc """
The first variables a terminal gives a shell or an exec (erx_shell's
terminal `vars`, command/2), checked once as they arrive: each name a
binary and each value a list of words, at most 256 bytes in all. A variable
of another shape is a fault of the code that built the terminal, which ends
the shell it was meant for.
""".
-spec first_vars(vars()) -> vars().
first_vars(Vars) when is_map(Vars) ->
    maps:map(fun first_value/2, Vars).

first_value(Name, Words) when is_binary(Name), is_list(Words) ->
    case lists:all(fun erlang:is_binary/1, Words) andalso iolist_size(Words) =< ?MAX_FIRST_VALUE of
        true -> Words;
        false -> error({bad_first_var, Name})
    end.

%% The body of the evaluator's process for Source, which ends with the source's ending.
evaluation(Source, Shell) ->
    fun() -> exit({ending, ending(erx_shell_eval:run_source(Source, Shell))}) end.

%% The evaluator's heap limit, so a runaway source ends it and never its caller (SH2).
heap_limit() ->
    {max_heap_size, #{size => ?MAX_HEAP_WORDS, kill => true, error_logger => false,
                      include_shared_binaries => true}}.

%% The source's ending from its evaluator's end, or the reason it was killed.
ending_of({ending, Ending}) -> Ending;
ending_of(Reason) -> {fault, iolist_to_binary(io_lib:format("~0tp", [Reason]))}.

%% How an exec ends on its group's exit signal: Ctrl-C's `interrupt` as `$status`
%% `sigint`, which erx_shell_jobs:exit_status/1 makes 130; any other ends the exec for
%% the same reason.
signalled(interrupt) -> {exit, <<"sigint">>};
signalled(Reason) -> exit(Reason).

ending({ok, Shell}) -> {ok, erx_shell_eval:status(Shell)};
ending({exit, Shell}) -> {exit, erx_shell_eval:status(Shell)};
ending({error, _Message, Shell}) -> {fault, erx_shell_eval:status(Shell)};
ending({syntax_error, _Printed, Shell}) -> {syntax_error, erx_shell_eval:status(Shell)}.

-doc """
`erl -run erx_shell_script main Script Output Work`: runs Script from the empty
directory Work, as the rc oracle runs its scripts, and writes `stdout`,
`stderr` and `status` into Output. `status` holds the ending and the
final `$status`, as erx_shell_fake_runner:main/1 writes them.
""".
-spec main([string()]) -> no_return().
main([Script, Output, Work]) ->
    {ok, Source} = file:read_file(Script),
    {ok, Out} = file:open(filename:join(Output, "stdout"), [write, binary]),
    {ok, Err} = file:open(filename:join(Output, "stderr"), [write, binary]),
    Vars = #{<<"0">> => [<<"../script.rc">>], <<"path">> => [<<"/bin">>, <<"/usr/bin">>],
             <<"home">> => [<<"/var/empty">>]},
    {Ending, Status} = run(Source, #{cwd => unicode:characters_to_binary(Work), vars => Vars,
                                     fds => #{0 => null, 1 => {dev, Out}, 2 => {dev, Err}}}),
    ok = file:close(Out),
    ok = file:close(Err),
    Outcome = case Ending of
                  fault -> <<"fault\n">>;
                  _ -> <<"ok\n">>
              end,
    ok = file:write_file(filename:join(Output, "status"), [Outcome, Status, $\n]),
    halt(0).
