%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_fs).
-moduledoc """
The Bluetooth domain's file service (docs/design-bluetooth.md, "The pairing window",
"Concurrency"): the process, registered as `erx_bt_fs`, that serves the control tree
through `erx_fs` grants of `erx_bt_fs_tree`, keeps its waiting reads and runs the
window's core, `erx_bt_window`. The core decides; this process does the effects: the
clock, one wake-up timer at the core's deadline, the monitors of links and of the grants
that opened `pair`, the messages to links, the log and the answers to the grants.

What reaches it:

* from a grant of the tree, the calls of `pair`'s open, first write and clunk, each
  answered at once, and its reads, which wait for a line as waiting requests the
  process keeps in an `erx_fs_waits` set (docs/design-files.md, "Waiting requests").
  After every step the waiting reads are offered the lines, in the order they came.
  A grant that ends closes every open it made, as its clunks would;
* from a link, `{erx_bt_link, Link, Message}` (docs/design-bluetooth.md, "The link's
  messages"), answered by `{window, Answer}` to the link's pid; an `open` verdict
  carries the pairing's fresh values (`erx_smp_crypto:fresh/0`), drawn here, so the
  core stays pure;
* from the store, `{outcome, Link, Tag, Outcome}`, the answer to a pairing's `keep`;
* a monitored link's `'DOWN'`.

The core's lines may hold a passkey and its verdicts carry fresh values, so a crash
report and `sys:get_status/1` show the core's `facts/1` alone.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-record(fs, {core :: erx_bt_window:core(),
             grants :: pid(),                                     % the tree's grants, linked
             links = #{} :: #{pid() => reference()},              % the monitored links
             opens = #{} :: #{reference() => erx_bt_window:id()}, % a monitor of each open's grant
             timer = none :: none | {reference(), integer()},
             waits = erx_fs_waits:new() :: erx_fs_waits:waits()}).

-doc """
Starts the service, registered as `erx_bt_fs`, over a store the start's read left
`read` or `unknown`, and the grants of its tree, linked.
""".
-spec start_link(read | unknown) -> gen_server:start_ret().
start_link(Store) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Store, []).

-doc false.
init(Store) ->
    process_flag(trap_exit, true),
    {ok, Grants} = erx_fs_grants:start_link(erx_bt_fs_tree, self()),
    {ok, #fs{core = erx_bt_window:new(Store), grants = Grants}}.

%% An open is named by the opening grant and a reference, and its grant is monitored, so
%% a grant's end closes it.
-doc false.
handle_call({open, Grant}, _From, Fs) when is_pid(Grant) ->
    Id = {Grant, make_ref()},
    case step({open, Id}, Fs) of
        {ok, #fs{opens = Opens} = Opened} ->
            {reply, {ok, Id}, Opened#fs{opens = Opens#{monitor(process, Grant) => Id}}};
        {Refused, Same} ->
            {reply, Refused, Same}
    end;
handle_call({write, Id, Mode}, _From, Fs) ->
    {Answer, Next} = step({write, Id, Mode}, Fs),
    {reply, Answer, Next};
handle_call({clunk, Id}, _From, #fs{opens = Opens} = Fs) ->
    [demonitor(Monitor, [flush]) || {Monitor, Open} <- maps:to_list(Opens), Open =:= Id],
    {_, Next} = step({clunk, Id}, Fs#fs{opens = maps:filter(fun(_, Open) -> Open =/= Id end, Opens)}),
    {reply, ok, Next};
handle_call(_Request, _From, Fs) ->
    {reply, {error, einval}, Fs}.

-doc false.
handle_cast(_Request, Fs) ->
    {noreply, Fs}.

-doc false.
handle_info({'EXIT', Grants, Reason}, #fs{grants = Grants} = Fs) ->
    {stop, {grants_ended, Reason}, Fs};
handle_info(Message, Fs) ->
    {noreply, event(Message, Fs)}.

%% The state shows as the core's facts; a message, which may be a link's passkey, as its
%% kind alone; and the log of sys events, which holds messages, as empty.
-doc false.
format_status(Status) ->
    maps:map(fun(state, #fs{core = Core}) -> erx_bt_window:facts(Core);
                (message, {erx_bt_link, Link, Message}) when is_tuple(Message) -> {erx_bt_link, Link, element(1, Message)};
                (log, _) -> [];
                (_, Value) -> Value
             end, Status).

%% ---------------------------------------------------------------------------
%% Events
%% ---------------------------------------------------------------------------

event({erx_bt_link, Link, Message}, Fs) when is_pid(Link) ->
    stepped({link, Link, Message}, Fs);
event({outcome, Link, Tag, Outcome}, Fs) ->
    stepped({store, {outcome, Link, Tag, Outcome}}, Fs);
event({timeout, Timer, wake}, #fs{timer = {Timer, _}} = Fs) ->
    stepped(expired, Fs#fs{timer = none});
event({'DOWN', Monitor, process, Pid, _} = Down, #fs{links = Links, opens = Opens} = Fs) ->
    case {Links, Opens} of
        {#{Pid := Monitor}, _} -> stepped({down, Pid}, Fs#fs{links = maps:remove(Pid, Links)});
        {_, #{Monitor := Id}} -> stepped({clunk, Id}, Fs#fs{opens = maps:remove(Monitor, Opens)});
        _ -> waits(Down, Fs)
    end;
event(?ERX_FS_WAIT(Wait, {read, _Id, _Count} = Read), #fs{waits = Waits} = Fs) ->
    pump(Fs#fs{waits = erx_fs_waits:hold(?ERX_FS_WAIT(Wait, Read), Waits)});
event(Message, Fs) ->
    waits(Message, Fs).

waits(Message, #fs{waits = Waits} = Fs) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> Fs#fs{waits = Settled};
        %% A read is never begun: it is answered in the step that takes its bytes.
        {dropped, Dropped} -> Fs#fs{waits = Dropped};
        %% A late timer, a demonitored link's or grant's end, or a stranger's message.
        unknown -> Fs
    end.

stepped(Input, Fs) ->
    {_, Next} = step(Input, Fs),
    Next.

%% One step of the core and its effects: the file request's answer is returned, the
%% rest done here, then the waiting reads offered the lines and the timer set.
step(Input, #fs{core = Core} = Fs) ->
    {Actions, Stepped} = erx_bt_window:step(Input, clock(), Core),
    {Answer, Done} = lists:foldl(fun perform/2, {none, Fs#fs{core = Stepped}}, Actions),
    {Answer, wake_up(pump(Done))}.

perform({answer, Answer}, {_, Fs}) ->
    {Answer, Fs};
perform({send, Link, {admission, Tag, {open, Mode}}}, Acc) ->
    Link ! {window, {admission, Tag, {open, Mode, erx_smp_crypto:fresh()}}},
    Acc;
perform({send, Link, Message}, Acc) ->
    Link ! {window, Message},
    Acc;
perform({monitor, Link}, {Answer, #fs{links = Links} = Fs}) ->
    {Answer, Fs#fs{links = Links#{Link => monitor(process, Link)}}};
perform({demonitor, Link}, {Answer, #fs{links = Links} = Fs}) ->
    {Monitor, Rest} = maps:take(Link, Links),
    demonitor(Monitor, [flush]),
    {Answer, Fs#fs{links = Rest}};
perform({log, #{address := Address, outcome := Outcome}}, Acc) ->
    ?LOG_NOTICE(#{what => bt_pairing, address => Address, outcome => Outcome}),
    Acc.

%% Each waiting read, in the order it came, takes what its open has: lines, or the end
%% of the file once they are read; a read whose open has no line yet waits.
pump(#fs{waits = Waits} = Fs) ->
    lists:foldl(fun offer/2, Fs, [{Wait, Id, Count} || {Wait, {read, Id, Count}, waiting} <- erx_fs_waits:list(Waits)]).

offer({Wait, Id, Count}, #fs{core = Core, waits = Waits} = Fs) ->
    case erx_bt_window:take(Id, Count, Core) of
        {none, _} -> Fs;
        {eof, Same} -> Fs#fs{core = Same, waits = erx_fs_waits:answer(Wait, {ok, <<>>}, Waits)};
        {{ok, Bytes}, Taken} -> Fs#fs{core = Taken, waits = erx_fs_waits:answer(Wait, {ok, Bytes}, Waits)}
    end.

%% One wake-up timer, at the core's next deadline.
wake_up(#fs{core = Core, timer = Timer} = Fs) ->
    case {erx_bt_window:next_deadline(Core), Timer} of
        {Deadline, {_, Deadline}} ->
            Fs;
        {Deadline, _} ->
            cancel(Timer),
            Fs#fs{timer = arm(Deadline)}
    end.

arm(infinity) -> none;
arm(Deadline) -> {erlang:start_timer(Deadline, self(), wake, [{abs, true}]), Deadline}.

cancel(none) -> ok;
cancel({Timer, _}) -> _ = erlang:cancel_timer(Timer), ok.

clock() -> erlang:monotonic_time(millisecond).
