%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_program).
-moduledoc """
A program command of the command shell (docs/design-shell.md, "Starting
programs"): a native program the runner starts with
erx_prog_handler:start/1, the calling process being its starter, and
waits for.

Finding it. find/1 maps a name the command namespace does not hold to
the program's image in the session's release: a name without `/` is
looked for in `/bin`, the release's `bin/`, and a path names a program
only as `/bin/NAME`. The driver refuses an image the release does not
hold with `einval`, and since every other field of the spec is the
shell's own and checked here, run/3 reads that refusal as `not found`.
A domain that runs no command server starts no program, and there every
such name is not found.

Its arguments and environment. `argv` is the name and the arguments; the
environment is every variable, a list's elements joined by byte 1 as
plan9port's rc exports lists, and `PATH=/bin`. Neither may hold a 0 byte,
which a C string cannot carry: such an argument is `einval`, and such a
variable is not exported. Their sizes are bounded by the startup
message's grammar, past which the start is `e2big`.

Its standard streams. Each of descriptors 0, 1 and 2 that the shell has
open is a pipe of the session's pipe server, whose other end a pump
process of the starter holds: an output pump writes what it reads to the
shell's stream unchanged, a terminal, an Erlang stage's pipe, a file or
nothing; an input pump feeds the program what it reads from an Erlang
stage's pipe or a file. Standard input that is the terminal or nothing is
a pipe already at its end, since the terminal's input reaches no program
yet (TODO.md). A pump that cannot write on stops reading, so a program
that writes on gets `EPIPE` as on UNIX. A closed descriptor stays closed.

Its end. The status is rc's: empty for exit 0, the exit status in decimal
otherwise, and the signal's name (`sigint`) for a program a signal ended.
It is given once the program has ended and its output pumps have written
what it wrote, so the next prompt follows its output. A handler that ends
without reporting the program's end, which happens only when the record
of it is lost, gives `no status`. An interrupt ends the starter, whose
end stops the program through its handler.
""".

-export([find/1, run/3]).

%% The most an output pump reads, or an input pump feeds, at once.
-define(CHUNK, 65536).

-doc """
The image of the program `Name` names, `{ok, Image}`, or `not_found`
for a name that names no program here, as described above.
""".
-spec find(binary()) -> {ok, binary()} | not_found.
find(Name) ->
    case {whereis(erx_command_srv), binary:split(Name, <<"/">>, [global])} of
        {undefined, _} -> not_found;
        {_, [Base]} -> image(Base);
        {_, [<<>>, <<"bin">>, Base]} -> image(Base);
        _ -> not_found
    end.

image(Base) when Base =:= <<>>; Base =:= <<".">>; Base =:= <<"..">> -> not_found;
image(Base) -> {ok, <<"bin/", Base/binary>>}.

-doc """
Runs the program `Image` with `Args` in the calling process as its
starter, with the context's name, working directory, environment and
standard streams (erx_cmd:ctx()), and gives its rc status, writing a
start's refusal to standard error. The caller is a process of its own,
since the program's pipe ends and pumps end with it.
""".
-spec run(binary(), [binary()], erx_cmd:ctx()) -> binary().
run(Image, Args, #{name := Name, cwd := Cwd, env := Vars} = Ctx) ->
    Argv = [Name | Args],
    case lists:any(fun has_nul/1, [Image | Argv]) of
        true -> refused(einval, Ctx);
        false -> plumbed(#{image => Image, argv => Argv, env => env(Vars), cwd => Cwd, spawn => false,
                           sigmask => [], sigignore => [], umask => 8#022}, Ctx)
    end.

%% The program started with its streams' pipes, and its status.
plumbed(Spec, Ctx) ->
    case pipes([{0, stdin}, {1, stdout}, {2, stderr}], Ctx, []) of
        {ok, Plumbing} ->
            Started = erx_prog_handler:start(Spec#{fds => [Fd || {Fd, _, _} <- Plumbing]}),
            %% As a UNIX parent closes its copies after the fork, so the
            %% pumps see the end of the stream once the program is gone.
            [ok = erx_pipe_srv:close(End) || {{_, {pipe, End}}, _, _} <- Plumbing],
            case Started of
                {ok, Handler, Watch, _Offsets} ->
                    Pumps = [Pump || Pump <- [pump(Other, Work) || {_, Other, Work} <- Plumbing], Pump =/= none],
                    ended(Handler, Watch, Pumps);
                {error, Errno} ->
                    refused(Errno, Ctx)
            end;
        {error, Errno} ->
            refused(Errno, Ctx)
    end.

%% A pipe for each open standard stream: the descriptor the program gets,
%% the other end, which the starter holds, and the pump's work on it.
pipes([], _Ctx, Plumbing) ->
    {ok, lists:reverse(Plumbing)};
pipes([{_Fd, Key} | Rest], Ctx, Plumbing) when map_get(Key, Ctx) =:= closed ->
    pipes(Rest, Ctx, Plumbing);
pipes([{Fd, Key} | Rest], Ctx, Plumbing) ->
    case {maps:get(Key, Ctx), erx_pipe_srv:pipe()} of
        {Stream, {ok, Read, Write}} when Fd =:= 0 ->
            pipes(Rest, Ctx, [{{Fd, {pipe, Read}}, Write, {feed, Stream}} | Plumbing]);
        {Stream, {ok, Read, Write}} ->
            pipes(Rest, Ctx, [{{Fd, {pipe, Write}}, Read, {drain, Stream}} | Plumbing]);
        {_, {error, _} = Refused} ->
            Refused
    end.

%% The pump of one end, by its kind, linked to the starter and monitored, or
%% none for an input at its end or an end the pipe server would not copy, which
%% the program then finds at its end or without a reader. The starter's own end
%% is closed once the pump holds one of its own.
pump(End, {feed, Stream}) when Stream =:= null; element(1, Stream) =:= tty ->
    ok = erx_pipe_srv:close(End),
    none;
pump(End, Work) ->
    {Pump, Ref} = spawn_opt(fun() -> receive {pump_end, Own} -> work(Own, Work) end end, [link, monitor]),
    Inherited = erx_pipe_srv:inherit(End, Pump),
    ok = erx_pipe_srv:close(End),
    case Inherited of
        {ok, Own} ->
            Pump ! {pump_end, Own},
            {element(1, Work), Pump, Ref};
        {error, _} ->
            unlink(Pump),
            exit(Pump, kill),
            demonitor(Ref, [flush]),
            none
    end.

work(End, {drain, Sink}) -> drain(End, Sink);
work(End, {feed, Source}) -> feed(End, Source).

drain(End, Sink) ->
    case erx_pipe_srv:read(End, ?CHUNK, infinity) of
        Bytes when is_binary(Bytes) ->
            case put_bytes(Sink, Bytes) of
                ok -> drain(End, Sink);
                stop -> ok
            end;
        _EofOrLost ->
            ok
    end.

put_bytes(Sink, Bytes) ->
    try erx_cmd:write(#{stdout => Sink}, Bytes)
    catch throw:{erx_cmd_stop, _} -> stop
    end.

feed(End, Source) ->
    case take(Source) of
        {bytes, Bytes} ->
            case erx_pipe_srv:write(End, Bytes, infinity) of
                ok -> feed(End, Source);
                {error, _} -> ok
            end;
        eof ->
            ok
    end.

take({pipe, Pipe}) ->
    erx_shell_pipe:get_bytes(Pipe);
take({dev, Device}) ->
    case file:read(Device, ?CHUNK) of
        {ok, Bytes} -> {bytes, iolist_to_binary(Bytes)};
        _EofOrError -> eof
    end.

%% The program's status once its handler has ended and every output pump
%% has written what it read. An input pump is stopped rather than awaited:
%% the program may have left input unread, and the stage that writes it
%% then sees its reader gone once the starter ends.
ended(Handler, Watch, Pumps) ->
    Status = receive
                 {'DOWN', Watch, process, Handler, {shutdown, {program_exit, Exit}}} ->
                     status(Exit);
                 {'DOWN', Watch, process, Handler, _} ->
                     <<"no status">>
             end,
    [receive {'DOWN', Ref, process, Pump, _} -> ok end || {drain, Pump, Ref} <- Pumps],
    [exit(Pump, kill) || {feed, Pump, _Ref} <- Pumps],
    Status.

status({exited, 0}) -> <<>>;
status({exited, N}) -> integer_to_binary(N);
status({signaled, Signal}) -> atom_to_binary(Signal).

%% A start the shell could not make: the diagnostic and the status.
refused(einval, #{name := Name} = Ctx) ->
    say(Ctx, [Name, <<": not found\n">>]),
    <<"not found">>;
refused(Errno, #{name := Name} = Ctx) ->
    Text = erx_cmd:format_error(Errno),
    say(Ctx, [Name, <<": ">>, Text, $\n]),
    Text.

say(Ctx, Bytes) ->
    try erx_cmd:say(Ctx, Bytes) catch throw:{erx_cmd_stop, _} -> ok end.

%% Every variable a program can be given, sorted by name, and PATH.
env(Vars) ->
    [<<"PATH=/bin">>
     | [iolist_to_binary([Name, $=, lists:join(<<1>>, Values)])
        || {Name, Values} <- lists:sort(maps:to_list(Vars)), exported(Name, Values)]].

exported(<<"PATH">>, _Values) -> false;
exported(Name, Values) ->
    Name =/= <<>> andalso binary:match(Name, <<"=">>) =:= nomatch
        andalso not lists:any(fun has_nul/1, [Name | Values]).

has_nul(Bin) -> binary:match(Bin, <<0>>) =/= nomatch.
