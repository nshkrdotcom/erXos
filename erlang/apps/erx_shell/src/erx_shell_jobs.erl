%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_jobs).
-moduledoc """
The job table of the command shell's interactive layer (docs/design-shell.md,
"Job control"): a pure state machine that erx_shell feeds what happens at
the terminal and what its jobs ask, and that answers with the next table
and the effects erx_shell then carries out, in order.

A job is identified by its **tag**, a term the shell chooses and the table
never looks into; erx_shell uses the group leader its processes share.
There are two kinds of foreground work:

* **The line.** The unit the shell is running is in the foreground and has
  no number. `Ctrl-C` ends it; `Ctrl-Z` stops it and gives it the lowest
  free number, as a UNIX shell numbers a job when it first has to show it.
* **A numbered job.** `&` on the shell's own line starts one in the
  background; a stopped line becomes one. While the line waits in `fg`, the
  job it brought forward is in the foreground with it, and `Ctrl-Z` and
  `Ctrl-C` reach that job first.

The table never holds the same tag twice, a job in the foreground is
running and has the line waiting for it, and a stopped job is never in the
foreground. `jobs` and the reports before a prompt follow FreeBSD sh's
form, `[N] + State  command`, where `+` marks the current job (the one most
recently started, stopped or continued) and `-` the previous one.

Effects, each carried out by erx_shell:

* `{stop, Tag}` pauses every process of the job;
* `{resume, Tag}` resumes the processes `stop` paused;
* `{terminate, Tag}` ends every process of the job and its tag, resuming
  any it paused after the end is sent, as `kill` of a stopped UNIX job
  continues it after the signal;
* `{release, Tag, keep | kill}`: the job's first process has ended; after
  a normal end its other processes stay with the tag, unlisted, until
  they end or the session does (`keep`), and after a crash they are
  ended with the tag (`kill`);
* `{finish_line, Tag}`: the line ended in the foreground, so the shell takes
  its outcome;
* `{say, Bytes}` writes to the terminal;
* `{answer, Waiter, Reply}` answers the line waiting in `fg`, or the
  process that asked to stop its own job;
* `{foreground, Target, Seen, Keep}` asks the terminal relay to give the
  terminal to Target (docs/design-shell.md, "The foreground rule"):
  `console`, `{Tag, cooked}`, `{Tag, Termios}` or `{Tag, current}`, with
  Seen the number of signal keys the table has taken; erx_shell gives the
  termios the answer says the previous holder left back to kept/3 with
  Keep, the tag of the job whose stop took the terminal, or `none`.

**The terminal follows the table.** The holder is a fact derived from the
table: the console with no line or while a shell runs above the line
(above/2, as `erl` does), else the job the line waits for in `fg`, else
the line. Every step ends in settle/2, which sends a `foreground` exactly
when that holder differs from the one last given, or `current` for the
job that holds when the step took a signal key, so no step has to know
whether it moved the terminal. The line runs under the cooked termios; a
job `fg` brings back under the termios its last stop left, or the cooked
one if it never stopped.

Job specifications and `kill`'s arguments are untrusted text: they are
matched against fixed binaries and bounded digit strings, and no atom is
made from them.
""".

-export([new/0, line/1, start_line/3, start_background/3, typed/3, above/2, kept/3,
         ended/3, foreground/3, background/2, signal/3, reap/1, list/1]).
-export([stop_own/3, foreground_tags/1]).
-export([parse_spec/1, parse_kill/1, signal_names/0, valid_request/1, line_tag/1]).
-export([exit_status/1]).
-export([invariant/1, view/1]).

-export_type([jobs/0, effect/0, result/0, spec/0, signal/0, target/0]).

-type tag() :: term().
-type waiter() :: term().
-type id() :: pos_integer().
%% What a job specification names: the current job, the previous one, or a number.
-type spec() :: current | previous | {id, id()}.
%% What a signal does to a job of Erlang commands: end it, stop it, or
%% continue it. The name is the signal's, as `kill -l` lists it.
-type signal() :: {terminate, binary()} | {stop, binary()} | {continue, binary()}.
%% How a job's first process ended: with an rc status, or by a crash or
%% its heap limit.
-type result() :: {exited, binary()} | failed.
%% A signal key typed at the terminal, and who reported it: the group, at
%% the console's editor, or the relay, naming the job that held the terminal.
-type key() :: interrupt | suspend | quit.
-type key_source() :: group | {tty, tag()}.
%% A termios as the relay hands it out; the table only keeps it.
-type termios() :: term().
%% What a `foreground` gives the terminal to.
-type target() :: console | {tag(), cooked | current | termios()}.
-type effect() :: {stop, tag()} | {resume, tag()} | {terminate, tag()}
                | {release, tag(), keep | kill} | {finish_line, tag()} | {interrupted, tag()}
                | {say, iodata()}
                | {answer, waiter(), {ok, binary()} | ok | {error, enotsup}}
                | {foreground, target(), non_neg_integer(), tag() | none}.

-record(job, {tag :: tag(),
              text :: binary(),
              run = running :: running | stopped | {done, iodata()},
              %% The signal that is ending the job, which its report names.
              ending = none :: none | binary(),
              %% The line waiting in `fg` for this job, while it is in the foreground.
              waiter = none :: none | {waiter, waiter()},
              %% The termios the job left when it last stopped holding the terminal.
              kept = none :: none | {kept, termios()}}).

-record(line, {tag :: tag(), text :: binary(),
               %% Whether a shell runs above the line, as `erl` runs one.
               above = false :: boolean()}).

-record(jobs, {line = none :: none | #line{},
               %% The numbered job the line brought to the foreground with `fg`.
               fg = none :: none | id(),
               table = #{} :: #{id() => #job{}},
               %% Job numbers, most recently started, stopped or continued first:
               %% the head is the current job and the next the previous one.
               order = [] :: [id()],
               %% The holder the last `foreground` named, and the number of
               %% signal keys taken.
               given = console :: console | tag(),
               seen = 0 :: non_neg_integer()}).

-opaque jobs() :: #jobs{}.

%% FreeBSD's signals that act on a job of Erlang commands, by name and
%% number, in the order `kill -l` lists them.
-define(SIGNALS, [{<<"HUP">>, 1, terminate}, {<<"INT">>, 2, terminate},
                  {<<"QUIT">>, 3, terminate}, {<<"KILL">>, 9, terminate},
                  {<<"TERM">>, 15, terminate}, {<<"STOP">>, 17, stop},
                  {<<"TSTP">>, 18, stop}, {<<"CONT">>, 19, continue}]).
%% A job number has at most this many digits, so no input makes a bignum.
-define(MAX_ID_DIGITS, 6).
%% The state column of a report, as wide as FreeBSD sh's.
-define(STATE_WIDTH, 24).

%%% The table

-doc "An empty table, with no line running.".
-spec new() -> jobs().
new() -> #jobs{}.

-doc "The tag of the line running in the foreground, or `none`.".
-spec line_tag(jobs()) -> tag() | none.
line_tag(#jobs{line = none}) -> none;
line_tag(#jobs{line = #line{tag = Tag}}) -> Tag.

-doc "Whether a line is running in the foreground.".
-spec line(jobs()) -> busy | idle.
line(#jobs{line = none}) -> idle;
line(#jobs{}) -> busy.

-doc """
Starts a line in the foreground, which takes the terminal; no line may be
running. erx_shell carries the effects out before the line runs.
""".
-spec start_line(tag(), binary(), jobs()) -> {[effect()], jobs()}.
start_line(Tag, Text, J = #jobs{line = none}) ->
    settle(0, {[], J#jobs{line = #line{tag = Tag, text = Text}}}).

-doc """
Starts a numbered job in the background, which becomes the current job, and
says its number as FreeBSD sh does.
""".
-spec start_background(tag(), binary(), jobs()) -> {id(), [effect()], jobs()}.
start_background(Tag, Text, J = #jobs{table = Table}) ->
    Id = free_id(Table),
    J1 = to_front(Id, J#jobs{table = Table#{Id => #job{tag = Tag, text = Text}}}),
    settled({Id, [{say, [$[, integer_to_binary(Id), <<"]\n">>]}], J1}).

-doc """
A signal key typed at the terminal, which the table counts whatever it
does. The group reports a key typed while the console holds the terminal
and names no job, so it acts on what is in the foreground; the relay names
the job that held the terminal, and the key acts only while that job is
still in the foreground, so a key that comes after its job ended or
stopped changes no other job. `Ctrl-C` (interrupt) and `Ctrl-\` (quit)
end what is in the foreground, the job the line waits for and the line,
and background jobs run on, as rc's `&` jobs ignore the interrupt; after
`Ctrl-C`, `{interrupted, Line}` tells the shell to go on with what it had
before the line, with `$status` saying the line was interrupted
(erx_shell_eval:interrupted/1). `Ctrl-Z` (suspend) stops the job the line
waits for in `fg`, whose `fg` returns, or else the line, which becomes a
numbered job. With nothing in
the foreground a key does nothing, as at a UNIX shell's prompt. The
relay's tty echoed its key, so the shell then writes only the newline;
the console's editing setting echoes nothing, so for a key the group
reports while a line runs the shell writes the key's caret form.
""".
-spec typed(key(), key_source(), jobs()) -> {[effect()], jobs()}.
typed(Key, group, J) ->
    settle(1, act_on_key(Key, echo(Key), J));
typed(Key, {tty, Tag}, J) ->
    case lists:member(Tag, foreground_tags(J)) of
        true -> settle(1, act_on_key(Key, <<"\n">>, J));
        false -> settle(1, {[], J})
    end.

echo(interrupt) -> <<"^C\n">>;
echo(quit) -> <<"^\\\n">>;
echo(suspend) -> <<"^Z\n">>.

act_on_key(suspend, Echo, J = #jobs{fg = Id}) when Id =/= none ->
    stop_job(Id, <<"sigtstp">>, Echo, J);
act_on_key(suspend, Echo, J = #jobs{line = #line{}}) ->
    stop_line(Echo, J);
act_on_key(_Key, _Echo, J = #jobs{line = none}) ->
    {[], J};
act_on_key(Key, Echo, J = #jobs{line = #line{tag = LineTag}, fg = Fg}) ->
    {Inner, J1} = case Fg of
                      none -> {[], J};
                      Id -> {[{terminate, tag(Id, J)}], remove(Id, J)}
                  end,
    Status = [{interrupted, LineTag} || Key =:= interrupt],
    {Inner ++ [{terminate, LineTag}] ++ Status ++ [{say, Echo}], J1#jobs{line = none, fg = none}}.

-doc """
A shell starts (`true`) or ends (`false`) above the line, as `erl` runs
the Erlang shell, whose group reads through the console: the console holds
the terminal while it runs. With no line it changes nothing.
""".
-spec above(boolean(), jobs()) -> {[effect()], jobs()}.
above(Above, J = #jobs{line = Line = #line{}}) ->
    settle(0, {[], J#jobs{line = Line#line{above = Above}}});
above(_Above, J = #jobs{line = none}) ->
    {[], J}.

-doc """
Keeps Left, the termios the relay's answer to a `foreground` says the
previous holder left, for the `fg` of the job Keep names, as the effect
gave it; `none`, or a job no longer held, keeps nothing.
""".
-spec kept(tag() | none, termios(), jobs()) -> jobs().
kept(none, _Left, J) ->
    J;
kept(Keep, Left, J) ->
    case find(Keep, J) of
        {Id, Job} -> put_job(Id, Job#job{kept = {kept, Left}}, J);
        none -> J
    end.

-doc """
A process of the job tagged Tag stops its own job, as a program raises
`SIGTSTP`: the job stops as `Ctrl-Z` or `kill -TSTP` stops it, with no
`^Z` echoed, since no key was typed, and Waiter, the process that asked,
is answered after the stop, so it takes the answer once the job is
continued. The line waiting in `fg` for a job cannot stop itself apart
from that job, and a tag the table does not hold has no job to stop: both
are answered `{error, enotsup}`. A job already stopped, as by `Ctrl-Z`
while the request waited, stays stopped, and Waiter, paused with it, takes
its `ok` once the job is continued.
""".
-spec stop_own(tag(), waiter(), jobs()) -> {[effect()], jobs()}.
stop_own(Tag, W, J = #jobs{line = #line{tag = Tag}, fg = none}) ->
    settle(0, answered(W, stop_line(<<>>, J)));
stop_own(Tag, W, J) ->
    case find(Tag, J) of
        {Id, #job{run = running}} -> settle(0, answered(W, stop_job(Id, <<"sigtstp">>, <<>>, J)));
        {_Id, #job{run = stopped}} -> {[{answer, W, ok}], J};
        _ -> {[{answer, W, {error, enotsup}}], J}
    end.

answered(W, {Effects, J}) -> {Effects ++ [{answer, W, ok}], J}.

-doc """
The tags of the jobs in the foreground: the line's, and the job's it waits
for in `fg`; none with no line.
""".
-spec foreground_tags(jobs()) -> [tag()].
foreground_tags(#jobs{line = none}) -> [];
foreground_tags(#jobs{line = #line{tag = Tag}, fg = none}) -> [Tag];
foreground_tags(J = #jobs{line = #line{tag = Tag}, fg = Id}) -> [Tag, tag(Id, J)].

-doc """
The first process of the job tagged Tag has ended with Result. The line
finishes; the job the line waits for answers it with its status; a
background job is done, and is reported before the next prompt. A tag the
table no longer holds, as of a job typed/3 ended, changes nothing.
""".
-spec ended(tag(), result(), jobs()) -> {[effect()], jobs()}.
ended(Tag, Result, J) -> settle(0, end_job(Tag, Result, J)).

end_job(Tag, Result, J = #jobs{line = #line{tag = Tag}, fg = Fg}) ->
    %% A line that ends while it waits in `fg`, as by its heap limit, leaves
    %% the job it waited for running in the background.
    J1 = case Fg of
             none -> J;
             Id -> put_job(Id, (maps:get(Id, J#jobs.table))#job{waiter = none}, J)
         end,
    {[{release, Tag, fate(Result)}, {finish_line, Tag}], J1#jobs{line = none, fg = none}};
end_job(Tag, Result, J) ->
    case find(Tag, J) of
        none ->
            {[], J};
        {Id, Job = #job{waiter = {waiter, W}}} ->
            Status = status(Result, Job),
            {[{release, Tag, fate(Result)}, {answer, W, {ok, Status}}],
             (remove(Id, J))#jobs{fg = none}};
        {Id, Job} ->
            Done = Job#job{run = {done, done_state(Result, Job)}, waiter = none},
            {[{release, Tag, fate(Result)}], put_job(Id, Done, J)}
    end.

-doc """
`fg`: brings the job Spec names to the foreground with the line, which
waits, as Waiter, until the job ends or stops; the job is resumed if it
was stopped, and its command is shown, as FreeBSD sh shows it.
""".
-spec foreground(spec(), waiter(), jobs()) ->
          {wait | {error, binary()}, [effect()], jobs()}.
foreground(Spec, W, J) -> settled(bring(Spec, W, J)).

bring(_Spec, _W, J = #jobs{line = none}) ->
    {{error, <<"no job control">>}, [], J};
bring(_Spec, _W, J = #jobs{fg = Fg}) when Fg =/= none ->
    {{error, <<"a job is in the foreground">>}, [], J};
bring(Spec, W, J) ->
    with_live_job(Spec, J,
                  fun(Id, Job = #job{tag = Tag, text = Text, run = Run}) ->
                          Resume = [{resume, Tag} || Run =:= stopped],
                          J1 = to_front(Id, put_job(Id, Job#job{run = running, waiter = {waiter, W}}, J)),
                          {wait, [{say, [escape(Text), $\n]} | Resume], J1#jobs{fg = Id}}
                  end).

-doc """
`bg`: continues the job Spec names in the background, and shows it as
FreeBSD sh does. A job already running is shown and left as it is.
""".
-spec background(spec(), jobs()) -> {ok | {error, binary()}, [effect()], jobs()}.
background(Spec, J) -> settled(continue(Spec, J)).

continue(Spec, J) ->
    with_live_job(Spec, J,
                  fun(Id, Job = #job{tag = Tag, text = Text, run = Run}) ->
                          Resume = [{resume, Tag} || Run =:= stopped],
                          J1 = to_front(Id, put_job(Id, Job#job{run = running}, J)),
                          Shown = [$[, integer_to_binary(Id), <<"] ">>, escape(Text), $\n],
                          {ok, Resume ++ [{say, Shown}], J1}
                  end).

-doc """
`kill`: sends Signal to the job Spec names. A signal that ends the job
ends every process it has and resumes any it stopped; the job is reported
done, with the signal named, once its first process has ended. `STOP` and
`TSTP` stop it, and `CONT` continues it in the background.
""".
-spec signal(signal(), spec(), jobs()) -> {ok | {error, binary()}, [effect()], jobs()}.
signal(Signal, Spec, J) -> settled(send_signal(Signal, Spec, J)).

send_signal(Signal, Spec, J) ->
    with_live_job(Spec, J, fun(Id, Job) -> signal_job(Signal, Id, Job, J) end).

signal_job({terminate, Name}, Id, Job = #job{tag = Tag}, J) ->
    {ok, [{terminate, Tag}], put_job(Id, Job#job{ending = Name}, J)};
signal_job({stop, Name}, Id, #job{run = running}, J) ->
    {Effects, J1} = stop_job(Id, <<"sig", (lower(Name))/binary>>, <<>>, J),
    {ok, Effects, J1};
signal_job({continue, _Name}, Id, Job = #job{tag = Tag, run = stopped}, J) ->
    {ok, [{resume, Tag}], to_front(Id, put_job(Id, Job#job{run = running}, J))};
signal_job(_Signal, _Id, _Job, J) ->
    %% Stopping a stopped job, or continuing a running one, changes nothing.
    {ok, [], J}.

-doc "The reports of the background jobs done since the last prompt, which leave the table.".
-spec reap(jobs()) -> {[effect()], jobs()}.
reap(J = #jobs{table = Table}) ->
    case [Id || Id <- lists:sort(maps:keys(Table)), is_done(maps:get(Id, Table))] of
        [] -> {[], J};
        Done -> {[{say, [report(Id, J) || Id <- Done]}], lists:foldl(fun remove/2, J, Done)}
    end.

-doc "`jobs`: a report of every numbered job; those done leave the table, as in FreeBSD sh.".
-spec list(jobs()) -> {iodata(), jobs()}.
list(J = #jobs{table = Table}) ->
    Ids = lists:sort(maps:keys(Table)),
    Done = [Id || Id <- Ids, is_done(maps:get(Id, Table))],
    {[report(Id, J) || Id <- Ids], lists:foldl(fun remove/2, J, Done)}.

-doc """
Whether the table's invariants hold: every tag appears once; the job in
the foreground exists, runs, has its waiter and comes with a line; no
other job has a waiter; and the order lists exactly the table's numbers.
Exported for the tests.
""".
-spec invariant(jobs()) -> boolean().
invariant(#jobs{line = Line, fg = Fg, table = Table, order = Order}) ->
    Tags = [T || #line{tag = T} <- [Line]] ++ [T || #job{tag = T} <- maps:values(Table)],
    Waiting = [Id || Id := #job{waiter = {waiter, _}} <- Table],
    FgOk = case Fg of
               none -> Waiting =:= [];
               _ -> Line =/= none andalso Waiting =:= [Fg]
                        andalso (maps:get(Fg, Table))#job.run =:= running
           end,
    length(Tags) =:= length(lists:usort(Tags)) andalso FgOk
        andalso lists:sort(Order) =:= lists:sort(maps:keys(Table))
        andalso length(Order) =:= length(lists:usort(Order)).

-doc """
The table as plain terms: the line's tag and whether a shell runs above
it, the number of the job in the foreground, each job's tag, state and
whether the line waits for it, the holder last given and the signal keys
taken. Exported for the tests.
""".
-spec view(jobs()) -> #{line := tag() | none, above := boolean(), fg := id() | none,
                        jobs := #{id() => {tag(), running | stopped | done, boolean()}},
                        given := console | tag(), seen := non_neg_integer()}.
view(#jobs{line = Line, fg = Fg, table = Table, given = Given, seen = Seen}) ->
    #{line => case Line of none -> none; #line{tag = T} -> T end,
      above => case Line of none -> false; #line{above = A} -> A end,
      given => Given,
      seen => Seen,
      fg => Fg,
      jobs => #{Id => {T, case Run of {done, _} -> done; _ -> Run end, W =/= none}
                || Id := #job{tag = T, run = Run, waiter = W} <- Table}}.

%%% Specifications and signals

-doc """
A job specification as FreeBSD sh reads one: `%%`, `%+` or `%` for the
current job, `%-` for the previous one, and `%N` for job N.
""".
-spec parse_spec(binary()) -> {ok, spec()} | error.
parse_spec(<<"%">>) -> {ok, current};
parse_spec(<<"%%">>) -> {ok, current};
parse_spec(<<"%+">>) -> {ok, current};
parse_spec(<<"%-">>) -> {ok, previous};
parse_spec(<<"%", Digits/binary>>) when byte_size(Digits) =< ?MAX_ID_DIGITS ->
    case digits(Digits) andalso binary_to_integer(Digits) of
        N when is_integer(N), N > 0 -> {ok, {id, N}};
        _ -> error
    end;
parse_spec(_Arg) ->
    error.

-doc """
`kill`'s arguments, as FreeBSD's kill takes them: `-l` lists the signals;
`-s NAME`, `-NAME` and `-NUMBER` name one, `TERM` by default, with or
without `SIG` and in either case; the rest are the jobs. A job argument
that names no job is the caller's to report, as `kill` reports each.
""".
-spec parse_kill([binary()]) -> list | {ok, signal(), [binary()]} | usage.
parse_kill([<<"-l">>]) -> list;
parse_kill([<<"-s">>, Name | Jobs]) -> with_signal(signal_by_name(Name), Jobs);
parse_kill([<<"--">> | Jobs]) -> with_signal(signal_by_name(<<"TERM">>), Jobs);
parse_kill([<<"-", Name/binary>> | Jobs]) when Name =/= <<>> ->
    case digits(Name) of
        true -> with_signal(signal_by_number(Name), Jobs);
        false -> with_signal(signal_by_name(Name), Jobs)
    end;
parse_kill(Jobs) -> with_signal(signal_by_name(<<"TERM">>), Jobs).

-doc "The signals `kill -l` lists, one line.".
-spec signal_names() -> binary().
signal_names() ->
    iolist_to_binary([lists:join($\s, [Name || {Name, _, _} <- ?SIGNALS]), $\n]).

-doc """
Whether Request has the shape of a request erx_shell takes from a runner:
`{background, Run}`, `{jobs}`, `{fg, Spec}`, `{bg, Spec}`, `{signal,
Signal, Spec}` or `{stop}`, with a specification parse_spec/1 could give and a signal
of the table. Any process can send the shell a request, so the shell
checks each before the table sees it.
""".
-spec valid_request(term()) -> boolean().
valid_request({background, Run}) -> is_function(Run, 0);
valid_request({jobs}) -> true;
valid_request({fg, Spec}) -> valid_spec(Spec);
valid_request({bg, Spec}) -> valid_spec(Spec);
valid_request({signal, Signal, Spec}) -> valid_signal(Signal) andalso valid_spec(Spec);
valid_request({stop}) -> true;
valid_request({above, Above}) -> is_boolean(Above);
valid_request(_Other) -> false.

valid_spec(current) -> true;
valid_spec(previous) -> true;
valid_spec({id, Id}) -> is_integer(Id) andalso Id > 0;
valid_spec(_Other) -> false.

valid_signal(Signal) -> lists:member(Signal, [{Action, Name} || {Name, _, Action} <- ?SIGNALS]).

-doc """
The exit status that `$status`'s text Status gives a shell that ends as a
program (docs/design-shell.md, "rc as a program"), read over the components
between its `|`s: 0 when every one is empty; otherwise the last non-empty one
decides, a decimal number from 0 to 255 being that status, a signal's name
(`sigint`) the status of a program that signal ended, 128 and the signal's
number, as FreeBSD's sh reports one, and anything else 1.
""".
-spec exit_status(binary()) -> 0..255.
exit_status(Status) when is_binary(Status) ->
    case [Part || Part <- binary:split(Status, <<"|">>, [global]), Part =/= <<>>] of
        [] -> 0;
        Parts -> component_status(lists:last(Parts))
    end.

component_status(Part) when byte_size(Part) =< 3 ->
    case digits(Part) andalso binary_to_integer(Part) of
        N when is_integer(N), N =< 255 -> N;
        _ -> signal_status(Part)
    end;
component_status(Part) ->
    signal_status(Part).

signal_status(Part) ->
    case lists:keyfind(upper(Part), 1, [{<<"SIG", Name/binary>>, N} || {Name, N, _} <- ?SIGNALS]) of
        {_, N} -> 128 + N;
        false -> 1
    end.

with_signal(error, _Jobs) -> usage;
with_signal(_Signal, []) -> usage;
with_signal(Signal, Jobs) -> {ok, Signal, Jobs}.

signal_by_name(Name0) ->
    Name = case upper(Name0) of
               <<"SIG", Rest/binary>> -> Rest;
               Upper -> Upper
           end,
    case lists:keyfind(Name, 1, ?SIGNALS) of
        {Name, _, Action} -> {Action, Name};
        false -> error
    end.

signal_by_number(Digits) when byte_size(Digits) =< 2 ->
    case lists:keyfind(binary_to_integer(Digits), 2, ?SIGNALS) of
        {Name, _, Action} -> {Action, Name};
        false -> error
    end;
signal_by_number(_Digits) ->
    error.

digits(<<>>) -> false;
digits(Bin) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)).

upper(Bin) -> << <<(case C of _ when C >= $a, C =< $z -> C - 32; _ -> C end)>> || <<C>> <= Bin >>.
lower(Bin) -> << <<(case C of _ when C >= $A, C =< $Z -> C + 32; _ -> C end)>> || <<C>> <= Bin >>.

%%% The terminal's holder

%% Where every step ends: Counted signal keys are added to those taken,
%% and the terminal goes to the holder the table now derives. A change of
%% holder sends that holder's `foreground`, with Keep naming the job that
%% gave the terminal up by stopping; a key that leaves a job holding sends
%% `current` for it, so the relay gives that job its reads back. The
%% `foreground` follows what the step does to processes and precedes its
%% answers, so a line released from `fg` finds the terminal back
%% (docs/design-shell.md, "The foreground rule": "`fg` then returns").
settle(Counted, {Effects, J0 = #jobs{given = Given, seen = Seen0}}) ->
    J = J0#jobs{seen = Seen0 + Counted},
    Target = target(J),
    case holder_of(Target) of
        Given when Counted > 0, Given =/= console ->
            {before_answers({foreground, {Given, current}, J#jobs.seen, none}, Effects), J};
        Given ->
            {Effects, J};
        Holder ->
            {before_answers({foreground, Target, J#jobs.seen, stopped(Given, J)}, Effects),
             J#jobs{given = Holder}}
    end.

before_answers(Foreground, Effects) ->
    {Answers, Acts} = lists:partition(fun(E) -> element(1, E) =:= answer end, Effects),
    Acts ++ [Foreground | Answers].

settled({Reply, Effects, J}) ->
    {Effects1, J1} = settle(0, {Effects, J}),
    {Reply, Effects1, J1}.

%% The `foreground` the table's state calls for.
target(#jobs{line = none}) -> console;
target(#jobs{line = #line{above = true}}) -> console;
target(#jobs{line = #line{tag = Tag}, fg = none}) -> {Tag, cooked};
target(J = #jobs{fg = Id}) ->
    case maps:get(Id, J#jobs.table) of
        #job{tag = Tag, kept = none} -> {Tag, cooked};
        #job{tag = Tag, kept = {kept, Termios}} -> {Tag, Termios}
    end.

holder_of(console) -> console;
holder_of({Tag, _Mode}) -> Tag.

%% The previous holder, when it is a job that has stopped.
stopped(console, _J) -> none;
stopped(Tag, J) ->
    case find(Tag, J) of
        {_Id, #job{run = stopped}} -> Tag;
        _ -> none
    end.

%%% Helpers

%% Stops job Id, which runs; if the line waits for it in `fg`, the line's
%% `fg` returns with Status and the job leaves the foreground. Echo comes
%% before the report: the terminal's `^Z`, or nothing for `kill`.
stop_job(Id, Status, Echo, J = #jobs{fg = Fg}) ->
    Job = #job{tag = Tag, waiter = Waiter} = maps:get(Id, J#jobs.table),
    J1 = to_front(Id, put_job(Id, Job#job{run = stopped, waiter = none}, J)),
    Answer = [{answer, W, {ok, Status}} || {waiter, W} <- [Waiter]],
    J2 = case Fg of
             Id -> J1#jobs{fg = none};
             _ -> J1
         end,
    {[{stop, Tag}, {say, [Echo, report(Id, J2)]} | Answer], J2}.

%% Stops the line in the foreground, which becomes a numbered job.
stop_line(Echo, J = #jobs{line = #line{tag = Tag, text = Text}, table = Table}) ->
    Id = free_id(Table),
    J1 = to_front(Id, J#jobs{line = none,
                             table = Table#{Id => #job{tag = Tag, text = Text, run = stopped}}}),
    {[{stop, Tag}, {say, [Echo, report(Id, J1)]}], J1}.

%% Runs Act on the job Spec names, if it is not done.
with_live_job(Spec, J, Act) ->
    case resolve(Spec, J) of
        {ok, Id} ->
            case maps:get(Id, J#jobs.table) of
                #job{run = {done, _}} -> {{error, <<"job has terminated">>}, [], J};
                Job -> Act(Id, Job)
            end;
        {error, Reason} ->
            {{error, Reason}, [], J}
    end.

resolve({id, Id}, #jobs{table = Table}) when is_map_key(Id, Table) -> {ok, Id};
resolve({id, _}, _J) -> {error, <<"no such job">>};
resolve(current, #jobs{order = [Id | _]}) -> {ok, Id};
resolve(current, _J) -> {error, <<"no current job">>};
resolve(previous, #jobs{order = [_, Id | _]}) -> {ok, Id};
resolve(previous, _J) -> {error, <<"no previous job">>}.

free_id(Table) -> free_id(1, Table).
free_id(Id, Table) when is_map_key(Id, Table) -> free_id(Id + 1, Table);
free_id(Id, _Table) -> Id.

to_front(Id, J = #jobs{order = Order}) -> J#jobs{order = [Id | lists:delete(Id, Order)]}.

put_job(Id, Job, J = #jobs{table = Table}) -> J#jobs{table = Table#{Id := Job}}.

remove(Id, J = #jobs{table = Table, order = Order}) ->
    J#jobs{table = maps:remove(Id, Table), order = lists:delete(Id, Order)}.

tag(Id, #jobs{table = Table}) -> (maps:get(Id, Table))#job.tag.

find(Tag, #jobs{table = Table}) ->
    case [{Id, Job} || Id := Job = #job{tag = T} <- Table, T =:= Tag] of
        [Found] -> Found;
        [] -> none
    end.

is_done(#job{run = {done, _}}) -> true;
is_done(#job{}) -> false.

fate({exited, _}) -> keep;
fate(failed) -> kill.

%% The status `fg` returns for a job that ended: its own, or the name of
%% the signal that ended it, as rc names one.
status(_Result, #job{ending = Name}) when Name =/= none -> <<"sig", (lower(Name))/binary>>;
status({exited, Status}, _Job) -> Status;
status(failed, _Job) -> <<"crashed">>.

%% The state column of a job that is done.
done_state(_Result, #job{ending = Name}) when Name =/= none -> signal_state(Name);
done_state({exited, <<>>}, _Job) -> <<"Done">>;
done_state({exited, Status}, _Job) -> [<<"Done(">>, escape(Status), $)];
done_state(failed, _Job) -> <<"Done(crashed)">>.

%% FreeBSD's names for the signals, as its sh reports a job one ended.
signal_state(<<"HUP">>) -> <<"Hangup">>;
signal_state(<<"INT">>) -> <<"Interrupt">>;
signal_state(<<"QUIT">>) -> <<"Quit">>;
signal_state(<<"KILL">>) -> <<"Killed">>;
signal_state(<<"TERM">>) -> <<"Terminated">>.

%% One job's line, `[N] + State  command`, as FreeBSD sh shows it.
report(Id, J = #jobs{table = Table}) ->
    #job{text = Text, run = Run} = maps:get(Id, Table),
    State = case Run of
                running -> <<"Running">>;
                stopped -> <<"Suspended">>;
                {done, Done} -> Done
            end,
    [$[, integer_to_binary(Id), <<"] ">>, mark(Id, J), $\s, pad(iolist_to_binary(State)),
     escape(Text), $\n].

mark(Id, #jobs{order = [Id | _]}) -> $+;
mark(Id, #jobs{order = [_, Id | _]}) -> $-;
mark(_Id, _J) -> $\s.

pad(State) when byte_size(State) < ?STATE_WIDTH ->
    [State, binary:copy(<<" ">>, ?STATE_WIDTH - byte_size(State))];
pad(State) ->
    [State, $\s].

%% A job's command and status reach the terminal through the line escape:
%% a status is a command's text, and a command may hold any byte.
escape(Text) -> erx_text:escape_line(Text).
