%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Edit 75 of docs/design-runtime.md, run on the tree's proc_lib, gen, gen_server and
%% gen_statem loaded over stock's: a process whose module exports format_status/1 keeps
%% every term it holds out of its terminate report and its crash report
%% (docs/design-log.md, "Reports carry no term"). Each server holds a secret in its
%% state, its dictionary, a message to itself and the arguments of the frame that fails;
%% a handler collects the reports, and no report may carry the secret's bytes. The same
%% server without format_status/1 leaks the secret, so the check is seen to find a leak.
%% No report filter runs: this is the system domain's case, which takes none.
-module(otp_report_status_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, fails/1]).

-define(HANDLER, otp_report_status).
-define(REPORTS, [{gen_server, terminate}, {gen_statem, terminate}, {proc_lib, crash}]).

%% The capturing handler: every report of a behaviour's end or of a crash, to the test.
log(#{msg := {report, #{label := Label}}} = Event, #{config := #{to := To}}) ->
    case lists:member(Label, ?REPORTS) of
        true -> To ! {logged, Label, Event};
        false -> ok
    end;
log(_Event, _Config) ->
    ok.

%% The modules the cases run are the tree's, from the work directory, not stock's.
tree_modules_are_loaded_test() ->
    {ok, Work} = file:get_cwd(),
    [?assertEqual(filename:basename(Work), filename:basename(filename:dirname(code:which(M))))
     || M <- [proc_lib, gen, gen_server, gen_statem]].

%% The plain server, this module, has no format_status/1, and its reports quote the
%% secret, as stock OTP's do.
server_without_format_status_leaks_the_secret_test() ->
    Reports = reports(gen_server, ?MODULE),
    ?assertEqual([{gen_server, terminate}, {proc_lib, crash}], labels(Reports)),
    [?assert(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% otp_report_status_hiding exports a format_status/1 that hides state, message, log and
%% reason, and neither report quotes the secret, which every one of them held.
server_with_format_status_hides_the_secret_test() ->
    Reports = reports(gen_server, otp_report_status_hiding),
    ?assertEqual([{gen_server, terminate}, {proc_lib, crash}], labels(Reports)),
    [?assertNot(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% otp_report_status_crashing is a gen_statem whose format_status/1 crashes, holding the
%% secret in its data, a postponed event, its queue and the failing frame: the reports
%% show gen's text for the crash and nothing of what the callback was asked to hide.
statem_whose_format_status_crashes_hides_the_secret_test() ->
    Reports = reports(gen_statem, otp_report_status_crashing),
    ?assertEqual([{gen_statem, terminate}, {proc_lib, crash}], labels(Reports)),
    [?assertNot(carries(Secret, Report)) || {Secret, Report} <- Reports].

%% gen_server callbacks of the plain server, which otp_report_status_hiding takes over.
init(Secret) ->
    put(held, Secret),
    {ok, {held, Secret}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.

handle_cast({hold, _Secret}, State) ->
    {noreply, State};
handle_cast({fail, Secret}, State) ->
    self() ! {held, Secret},
    fails(Secret),
    {noreply, State}.

handle_info(_Message, State) -> {noreply, State}.

%% A clause that fails on the secret, which is a binary: the frame's argument is it.
fails(Atom) when is_atom(Atom) -> ok.

%% Starts Behaviour's server Mod, holding a fresh secret, fails it and returns each report
%% it logged, with the secret, sorted by label.
reports(Behaviour, Mod) ->
    Secret = <<"SECRET-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ok = logger:add_handler(?HANDLER, ?MODULE, #{config => #{to => self()}}),
    try
        {ok, Pid} = Behaviour:start(Mod, Secret, []),
        Monitor = monitor(process, Pid),
        ok = Behaviour:cast(Pid, {hold, Secret}),
        ok = Behaviour:cast(Pid, {fail, Secret}),
        receive {'DOWN', Monitor, process, Pid, _Reason} -> ok after 5000 -> error(no_exit) end,
        lists:sort([{Secret, Report} || Report <- collected(2)])
    after
        ok = logger:remove_handler(?HANDLER)
    end.

collected(0) -> [];
collected(N) ->
    receive {logged, Label, Event} -> [{Label, Event} | collected(N - 1)]
    after 5000 -> error({reports_missing, N})
    end.

labels(Reports) -> [Label || {_Secret, {Label, _Event}} <- Reports].

carries(Secret, {_Label, Event}) -> binary:match(term_to_binary(Event), Secret) =/= nomatch.
