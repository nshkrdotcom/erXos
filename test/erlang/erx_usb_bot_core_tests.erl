%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_bot_core (docs/design-usb.md, "The BOT engine" and "Media and
%% drives"): the engine explored to a fixed point over two units, two media generations
%% a unit and every CSW and sense outcome, against a model device and the invariants the
%% design states; BOT 1.0's thirteen cases (section 6.7) as a table; traces of autosense,
%% readiness, the medium reference, the deadlines and the start; and the decoders on
%% written cases. Every number is written out here, so a bound changed in
%% abi/formats/usb.txt fails a case instead of moving with the module.
-module(erx_usb_bot_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([explore/0]).

-define(CSW_SIGNATURE, 16#53425355).
-define(NOT_READY, 2).
-define(MEDIUM_ERROR, 3).
-define(ILLEGAL_REQUEST, 5).
-define(UNIT_ATTENTION, 6).


%% ---------------------------------------------------------------------------------------
%% The engine explored to a fixed point.
%%
%% The model plays the function and the device. The function submits a script of
%% requests, in order, each either while the engine is idle or just after it posts a CBW,
%% which puts the request in the queue behind a whole operation. A write's two data bytes
%% name its unit and medium, so the device knows which medium a write is for.
%%
%% Two kinds of model, each explored to a fixed point:
%% * every first operation: from an engine whose unit 0 has a medium, one operation of
%%   each kind (a write, a flush, a read, an INQUIRY, a readiness) with requests queued
%%   behind it, the device answering the operation every way the design distinguishes: a
%%   CBW taken or stalled; a data phase whole, short or stalled; a CSW good, good with all
%%   its length left over, failed, a phase error, of another tag, with a residue past its
%%   length, or stalled, and again after the stall; sense data of the key the device
%%   holds, short, or of an unknown format; each step of reset recovery done or failed.
%%   The requests behind it are answered with success, so the model stays small;
%% * two units, two media generations a unit: a script that makes each unit's first
%%   medium ready, writes and flushes it, makes its second medium ready, writes the first
%%   again, ended by then if the device reported its end, and writes the second, the
%%   device answering each operation with every outcome class: success, a phase error,
%%   or a failed status whose sense is read or fails.
%% The split keeps the exploration a second long: every CSW and sense outcome in every
%% medium generation would multiply the outcomes of each operation across the script.
%% Time stands still in both; the deadlines are covered by the traces below.
%% A failed status with a meaningful CSW holds a sense: UNIT ATTENTION, NOT READY, ILLEGAL
%% REQUEST or MEDIUM ERROR, the first two ending the unit's medium on the device at that
%% moment.
%%
%% The invariants, checked at every step:
%% * a CSW calls for reset recovery exactly when BOT 1.0 says (6.3, 6.5): invalid, not
%%   meaningful, a phase error, or a metadata command's relevant bytes past what moved;
%% * REQUEST SENSE is sent only right after a meaningful failed status of another command
%%   on its unit;
%% * no write is sent for a medium that has ended, on the device or in the engine;
%% * a medium ends in the engine only as its unit's current one;
%% * a medium becomes ready only on a unit with none, and flushes exactly when its
%%   readiness drew no ILLEGAL REQUEST; a flush of one that cannot is answered no_flush;
%% * every request is answered once, and, unless the function stopped, every request is
%%   answered when nothing is left to happen.
the_engine_explored_keeps_its_invariants_test_() ->
    {timeout, 600, fun() -> ?assertMatch({ok, _}, explore()) end}.

explore() ->
    explore_models([first_write, first_flush, first_read, first_inquiry, first_ready, two_units], []).

explore_models([], Counts) ->
    io:format(user, "~nerx_usb_bot_core explored to a fixed point: ~p~n", [lists:reverse(Counts)]),
    {ok, lists:reverse(Counts)};
explore_models([Name | Rest], Counts) ->
    {State, Model} = model(Name),
    case explore([{State, Model}], #{{State, Model} => true}) of
        {ok, Seen} -> explore_models(Rest, [{Name, Seen} | Counts]);
        {error, Why} -> {error, {Name, Why}}
    end.

%% The engine and model each kind starts from. Unit 0's first medium is ready, but for
%% the two-unit model, which makes every medium ready itself.
model(Name) ->
    {Ready, First} = ready(started(), 0, true),
    Refs = #{{0, 1} => First, {0, 2} => make_ref(), {1, 1} => make_ref(), {1, 2} => make_ref()},
    Ref = fun(Lun, Gen) -> maps:get({Lun, Gen}, Refs) end,
    Write = fun(Lun, Gen) -> {Ref(Lun, Gen), {write, Lun, 0, <<Lun, Gen>>}} end,
    {State, Mode, Current, Script} =
        case Name of
            first_write -> {Ready, full, First, [Write(0, 1), Write(0, 1), {none, {test_unit_ready, 1}}]};
            first_flush -> {Ready, full, First, [{First, {flush, 0}}, Write(0, 1)]};
            first_read -> {Ready, full, First, [{First, {read, 0, 0, 1}}, Write(0, 1)]};
            first_inquiry -> {Ready, full, First, [{none, {inquiry, 1}}, Write(0, 1)]};
            first_ready -> {Ready, full, First, [{none, {ready, 1, Ref(1, 1)}}, {Ref(1, 1), {flush, 1}},
                                                 Write(1, 1)]};
            two_units ->
                {started(), classes, none,
                 [{none, {ready, 0, Ref(0, 1)}}, {none, {ready, 1, Ref(1, 1)}}, Write(0, 1), Write(1, 1),
                  {Ref(0, 1), {flush, 0}}, {none, {ready, 0, Ref(0, 2)}}, Write(0, 1), {none, {ready, 1, Ref(1, 2)}},
                  Write(0, 2), Write(1, 2)]}
        end,
    {State, #{refs => Refs, script => Script, cursor => 1, answered => [], mode => Mode, pending => none,
              current => #{0 => Current, 1 => none}, dead => [], flushless => [], held => none,
              sense_allowed => none, last_key => #{0 => none, 1 => none}, wire => none, wire_tag => none,
              moved => 0, stopped => false}}.

explore([], Seen) ->
    {ok, map_size(Seen)};
explore([{State, Model} | Rest], Seen) ->
    case events(Model) of
        [] ->
            case finished(Model) of
                ok -> explore(Rest, Seen);
                {error, Why} -> {error, Why}
            end;
        Events ->
            case follow_all(Events, State, Model, []) of
                {ok, Nodes} ->
                    New = lists:usort([Node || Node <- Nodes, not is_map_key(Node, Seen)]),
                    explore(New ++ Rest, maps:merge(Seen, maps:from_keys(New, true)));
                {error, Why} ->
                    {error, Why}
            end
    end.

follow_all([], _State, _Model, Nodes) ->
    {ok, Nodes};
follow_all([{Event, Heard} | Rest], State, Model, Nodes) ->
    {Next, Actions} = erx_usb_bot_core:step(Event, 0, State),
    case observe(Heard, Actions, heard(Heard, Model)) of
        {ok, M} -> follow_all(Rest, State, Model, [{Next, M} | Nodes]);
        {error, Why} -> {error, {Why, Event, Actions}}
    end.

%% The events possible in Model: the answer to the transfer the engine waits on, and the
%% script's next request while the function is not inside a call.
events(#{stopped := true}) ->
    [];
events(Model = #{pending := {sync, Action}}) ->
    device(Action, Model);
events(Model = #{pending := Pending, script := Script, cursor := Cursor}) ->
    Answers = case Pending of
                  {bulk, Action} -> device(Action, Model);
                  none -> []
              end,
    Next = [begin
                {Medium, Request} = lists:nth(Cursor, Script),
                {{request, Cursor, Medium, Request}, submitted}
            end || submits(Pending), Cursor =< length(Script)],
    Answers ++ Next.

submits(none) -> true;
submits({bulk, {command, _Tag, _Command}}) -> true;
submits(_Pending) -> false.

%% The device's answers to Action, each paired with what the model remembers of it.
device(class_reset, #{mode := Mode}) ->
    [{{control, {ok, <<>>}}, done} | [{{control, {error, stall}}, done} || Mode =:= full]];
device({reset_pipe, _Pipe}, #{mode := Mode}) ->
    [{{reset_pipe, ok}, done} | [{{reset_pipe, {error, gone}}, done} || Mode =:= full]];
device({command, Tag, _Command}, #{mode := Mode}) ->
    [{{transfer, Tag, {ok, 31}}, done} | [{{transfer, Tag, {error, stall}}, {moved, 0}} || Mode =:= full]];
device({data_out, Tag, {write, _Lun, _Sector, Data}}, #{mode := Mode}) ->
    Whole = byte_size(Data),
    [{{transfer, Tag, {ok, Whole}}, {moved, Whole}}
     | [Answer || Mode =:= full, Answer <- [{{transfer, Tag, {ok, Whole - 1}}, {moved, Whole - 1}},
                                            {{transfer, Tag, {error, stall}}, {moved, 0}}]]];
device({data_in, Tag, _Length}, #{mode := Mode, wire := Command, held := Held}) ->
    {Whole, Partial} = data(Command, Held),
    [{{transfer, Tag, {ok, Whole}}, {data, Whole}}
     | [Answer || Mode =:= full, Answer <- [{{transfer, Tag, {ok, Bytes}}, {data, Bytes}} || Bytes <- Partial]
                                           ++ [{{transfer, Tag, {error, stall}}, {moved, 0}}]]];
device({status, Tag}, #{mode := Mode, wire := Command}) ->
    Length = length_of(Command),
    Csw = fun(T, Residue, Status, Held) ->
                  {{transfer, Tag, {ok, csw(T, Residue, Status)}}, {csw, T, Residue, Status, Held}}
          end,
    Failed = case Command of
                 {request_sense, _Lun} -> [Csw(Tag, 0, 1, none)];
                 _Other -> [Csw(Tag, 0, 1, Key)
                            || Key <- [?UNIT_ATTENTION, ?NOT_READY, ?ILLEGAL_REQUEST, ?MEDIUM_ERROR]]
             end,
    case Mode of
        success -> [Csw(Tag, 0, 0, none)];
        classes -> [Csw(Tag, 0, 0, none), Csw(Tag, 0, 2, none) | Failed];
        full -> [Csw(Tag, 0, 0, none), Csw(Tag, Length, 0, none), Csw(Tag, 0, 2, none), Csw(Tag + 1, 0, 0, none),
                 Csw(Tag, Length + 1, 0, none), {{transfer, Tag, {error, stall}}, done} | Failed]
    end.

%% The data a data-in command's device sends whole, and the partial answers it may give:
%% sense data of the key it holds, short or of another format; a read short by half; an
%% INQUIRY's header alone or less.
data({request_sense, _Lun}, Held) ->
    Key = case Held of
              {_Unit, K} -> K;
              none -> 0
          end,
    {sense_bytes(16#70, Key), [binary:part(sense_bytes(16#70, Key), 0, 13), sense_bytes(16#72, Key)]};
data({read, _Lun, _Sector, Count}, _Held) ->
    {binary:copy(<<16#5a>>, 512 * Count), [binary:copy(<<16#5a>>, 256 * Count)]};
data({inquiry, _Lun}, _Held) ->
    {inquiry_bytes(36), [inquiry_bytes(5), inquiry_bytes(4)]}.

%% What the model learns from the answer it gave, before it reads the engine's actions.
heard(submitted, Model = #{cursor := Cursor}) ->
    Model#{cursor := Cursor + 1};
heard(done, Model) ->
    Model#{pending := none};
heard({moved, Moved}, Model) ->
    Model#{pending := none, moved := Moved};
heard({data, Bytes}, Model = #{wire := {request_sense, Lun}, last_key := Keys}) ->
    Key = case sense_key(Bytes) of
              {ok, K} -> K;
              none -> maps:get(Lun, Keys)
          end,
    Model#{pending := none, moved := byte_size(Bytes), last_key := Keys#{Lun := Key}};
heard({data, Bytes}, Model) ->
    Model#{pending := none, moved := byte_size(Bytes)};
heard({csw, _Tag, _Residue, _Status, Held}, Model = #{wire := Command, current := Current, dead := Dead}) ->
    Lun = element(2, Command),
    Ended = case Held of
                Key when Key =:= ?UNIT_ATTENTION; Key =:= ?NOT_READY -> [maps:get(Lun, Current)];
                _Kept -> []
            end,
    Model#{pending := none, held := held(Lun, Held), dead := lists:usort(Dead ++ [Ref || Ref <- Ended, Ref =/= none])}.

%% The key of 18 bytes of fixed-format sense data as the device sent it, read here from
%% the written layout: response code 70h, key in byte 2.
sense_key(<<16#70, _, Key, _:15/binary>>) -> {ok, Key};
sense_key(_Other) -> none.

held(_Lun, none) -> none;
held(Lun, Key) -> {Lun, Key}.

%% Reads the engine's actions after the answer Heard, checking each invariant.
observe(Heard, Actions, Model) ->
    try
        case expects_reset(Heard, Model) of
            none -> ok;
            Reset -> check(lists:member(class_reset, Actions) =:= Reset, {reset_expected, Reset})
        end,
        Allowed = sense_allowed(Heard, Model),
        {ok, idle(lists:foldl(fun action/2, Model#{sense_allowed := Allowed}, Actions))}
    catch
        throw:{violation, Why} -> {error, Why}
    end.

%% Whether a CSW calls for reset recovery, by BOT 1.0's rules written here.
expects_reset({csw, Tag, Residue, Status, _Held}, #{wire := Command, wire_tag := WireTag, moved := Moved}) ->
    Length = length_of(Command),
    if
        Tag =/= WireTag -> true;
        Status =:= 2 -> true;
        Residue > Length -> true;
        Status =:= 0 -> metadata(Command) andalso Length - Residue > Moved;
        true -> false
    end;
expects_reset(_Heard, _Model) ->
    none.

sense_allowed({csw, Tag, Residue, 1, _Held}, #{wire := Command, wire_tag := WireTag}) ->
    case Tag =:= WireTag andalso Residue =< length_of(Command) andalso element(1, Command) =/= request_sense of
        true -> element(2, Command);
        false -> none
    end;
sense_allowed(_Heard, #{sense_allowed := Allowed}) ->
    Allowed.

%% With no transfer outstanding the engine is idle, and what the model kept of the last
%% command no longer matters; forgetting it lets idle states that differ only by it merge.
idle(Model = #{pending := none}) ->
    Model#{wire := none, wire_tag := none, moved := 0, held := none, sense_allowed := none,
           last_key := #{0 => none, 1 => none}};
idle(Model) ->
    Model.

action({command, Tag, Command}, Model = #{sense_allowed := Allowed, dead := Dead, refs := Refs,
                                          last_key := Keys}) ->
    Lun = element(2, Command),
    case Command of
        {request_sense, Lun} -> check(Allowed =:= Lun, {sense_not_after_failure, Lun});
        {write, Lun, _Sector, <<Lun, Gen>>} -> check(not lists:member(maps:get({Lun, Gen}, Refs), Dead),
                                                    {write_to_ended_medium, Lun, Gen});
        _Other -> ok
    end,
    Fresh = case Command of
                {request_sense, _} -> Model;
                _NewCommand -> Model#{held := none, last_key := Keys#{Lun := none}}
            end,
    Fresh#{pending := {bulk, {command, Tag, Command}}, wire := Command, wire_tag := Tag, moved := 0,
           sense_allowed := none};
action(Transfer = {Kind, _Tag, _}, Model) when Kind =:= data_in; Kind =:= data_out ->
    Model#{pending := {bulk, Transfer}};
action(Transfer = {status, _Tag}, Model) ->
    Model#{pending := {bulk, Transfer}};
action(Sync, Model) when Sync =:= class_reset; Sync =:= get_max_lun; element(1, Sync) =:= reset_pipe ->
    Model#{pending := {sync, Sync}};
action({stop, _Reason}, Model) ->
    Model#{stopped := true};
action({medium_ended, Lun, Ref}, Model = #{current := Current, dead := Dead}) ->
    check(maps:get(Lun, Current) =:= Ref, {ended_not_current, Lun}),
    Model#{current := Current#{Lun := none}, dead := lists:usort([Ref | Dead])};
action({answer, Index, Reply}, Model = #{answered := Answered, cursor := Cursor, script := Script, mode := Mode}) ->
    check(not lists:member(Index, Answered) andalso Index < Cursor, {answer_twice_or_unasked, Index}),
    {Medium, Request} = lists:nth(Index, Script),
    Next = case {Mode, Index} of
               {full, 1} -> success;
               _Same -> Mode
           end,
    answered(Medium, Request, Reply, Model#{answered := ordsets:add_element(Index, Answered), mode := Next}).

answered(_None, {ready, Lun, Ref}, {ok, #{flush := Flush}}, Model = #{current := Current, flushless := Flushless,
                                                                     last_key := Keys}) ->
    check(maps:get(Lun, Current) =:= none, {ready_over_a_medium, Lun}),
    check(Flush =:= (maps:get(Lun, Keys) =/= ?ILLEGAL_REQUEST), {flush_misjudged, Lun, Flush}),
    Model#{current := Current#{Lun := Ref}, flushless := lists:usort([Ref || not Flush] ++ Flushless)};
answered(Ref, {flush, _Lun}, Reply, Model = #{flushless := Flushless}) ->
    case lists:member(Ref, Flushless) of
        true -> check(lists:member(Reply, [{error, no_flush}, {error, {device, gone}}]), {flush_answered, Reply});
        false -> ok
    end,
    Model;
answered(_Medium, _Request, _Reply, Model) ->
    Model.

%% With nothing left to happen, every request of the script has its answer.
finished(#{stopped := true}) ->
    ok;
finished(#{answered := Answered, script := Script}) ->
    check_unanswered(length(Script) - length(Answered)).

check_unanswered(0) -> ok;
check_unanswered(N) -> {error, {unanswered, N}}.

length_of(Command) -> element(2, data_phase(Command)).

%% Each command's data length, written out here.
data_phase({request_sense, _Lun}) -> {in, 18};
data_phase({inquiry, _Lun}) -> {in, 36};
data_phase({read, _Lun, _Sector, Count}) -> {in, 512 * Count};
data_phase({write, _Lun, _Sector, Data}) -> {out, byte_size(Data)};
data_phase({_NoData, _Lun}) -> {none, 0}.

metadata({request_sense, _Lun}) -> true;
metadata({inquiry, _Lun}) -> true;
metadata(_Command) -> false.

check(true, _Why) -> ok;
check(false, Why) -> throw({violation, Why}).

%% ---------------------------------------------------------------------------------------
%% BOT 1.0's thirteen cases (section 6.7), each as what the device does and what the
%% engine answers: Hn by TEST UNIT READY, Hi by INQUIRY, Ho by a WRITE of two sectors.

the_thirteen_cases_test() ->
    Inquiry = {inquiry, 0},
    Tur = {test_unit_ready, 0},
    Write = {write, 0, 0, binary:copy(<<16#a5>>, 1024)},
    Reset = [ok, ok, ok],
    {Ready, Ref} = ready(started(), 0, true),
    Cases =
        [{1, Tur, [ok, {csw, 0, 0}], ok, false},
         {2, Tur, [ok, {csw, 0, 2} | Reset], {error, {device, reset}}, true},
         {3, Tur, [ok, stall, ok, {csw, 0, 2} | Reset], {error, {device, reset}}, true},
         {4, Inquiry, [ok, stall, ok, {csw, 36, 0}], {error, {device, short}}, false},
         {5, Inquiry, [ok, {data, inquiry_bytes(5)}, stall, ok, {csw, 31, 0}],
          {ok, #{type => 0, qualifier => 0, removable => true}}, false},
         {6, Inquiry, [ok, {data, inquiry_bytes(36)}, {csw, 0, 0}],
          {ok, #{type => 0, qualifier => 0, removable => true, vendor => <<"erXos   ">>,
                 product => <<"test stick      ">>}}, false},
         {7, Inquiry, [ok, {data, inquiry_bytes(36)}, stall, ok, {csw, 0, 2} | Reset], {error, {device, reset}}, true},
         {8, Inquiry, [ok, stall, ok, {csw, 36, 2} | Reset], {error, {device, reset}}, true},
         {9, Write, [ok, stall, ok, {csw, 1024, 0}], {error, {device, short}}, false},
         {10, Write, [ok, stall, ok, {csw, 1024, 2} | Reset], {error, {device, reset}}, true},
         {11, Write, [ok, {moved, 1024}, {csw, 512, 0}], {error, {device, short}}, false},
         {12, Write, [ok, {moved, 1024}, {csw, 0, 0}], ok, false},
         {13, Write, [ok, {moved, 1024}, {csw, 0, 2} | Reset], {error, {device, reset}}, true}],
    [begin
         {_State, Actions, Left} = run(Ready, [{request, Case, Ref, Request}], Script),
         ?assertEqual({Case, [Reply]}, {Case, replies(Actions)}),
         ?assertEqual({Case, ResetRan}, {Case, lists:member(class_reset, Actions)}),
         ?assertEqual({Case, []}, {Case, Left})
     end || {Case, Request, Script, Reply, ResetRan} <- Cases],
    %% A data phase that stalls is cleared on its own pipe.
    {_, Cleared, _} = run(Ready, [{request, w, Ref, Write}], [ok, stall, ok, {csw, 1024, 0}]),
    ?assert(lists:member({reset_pipe, out}, Cleared)).

%% ---------------------------------------------------------------------------------------
%% Traces.

a_failed_command_is_explained_by_its_sense_before_anything_else_runs_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    Write = {write, 0, 7, <<1, 2>>},
    {S1, [{command, Tag, Write}]} = step({request, w1, Ref, Write}, Ready),
    %% Queued behind it: another write for the same medium and a request of the other unit.
    {S2, []} = step({request, w2, Ref, {write, 0, 8, <<3, 4>>}}, S1),
    {S3, []} = step({request, other, none, {test_unit_ready, 1}}, S2),
    {S4, [{data_out, Tag, Write}]} = step({transfer, Tag, {ok, 31}}, S3),
    {S5, [{status, Tag}]} = step({transfer, Tag, {ok, 2}}, S4),
    {S6, [{command, Sense, {request_sense, 0}}]} = step({transfer, Tag, {ok, csw(Tag, 0, 1)}}, S5),
    {S7, [{data_in, Sense, 18}]} = step({transfer, Sense, {ok, 31}}, S6),
    {S8, [{status, Sense}]} = step({transfer, Sense, {ok, sense_bytes(16#70, ?UNIT_ATTENTION, 16#28, 0)}}, S7),
    {_S9, Actions} = step({transfer, Sense, {ok, csw(Sense, 0, 0)}}, S8),
    ?assertMatch([{answer, w1, {error, {device, {sense, ?UNIT_ATTENTION, 16#28, 0}}}},
                  {answer, w2, {error, {device, gone}}},
                  {medium_ended, 0, Ref},
                  {command, _, {test_unit_ready, 1}}], Actions).

a_sense_that_fails_ends_the_medium_and_is_not_asked_again_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    Write = {write, 0, 0, <<1>>},
    Failing = [ok, {moved, 1}, {csw, 0, 1}, ok],
    Ends = fun(Script) ->
                   {_, Actions, []} = run(Ready, [{request, w, Ref, Write}], Failing ++ Script),
                   ?assertEqual([{error, {device, no_sense}}], replies(Actions)),
                   ?assert(lists:member({medium_ended, 0, Ref}, Actions)),
                   ?assertEqual(1, length([C || {command, _, C = {request_sense, _}} <- Actions]))
           end,
    Ends([{data, sense_bytes(16#70, ?MEDIUM_ERROR)}, {csw, 0, 1}]),
    Ends([{data, binary:part(sense_bytes(16#70, ?MEDIUM_ERROR), 0, 13)}, {csw, 5, 0}]),
    Ends([{data, sense_bytes(16#72, ?MEDIUM_ERROR)}, {csw, 0, 0}]),
    Ends([{data, sense_bytes(16#70, ?MEDIUM_ERROR)}, {raw, <<0:13/unit:8>>}, ok, ok, ok]),
    Ends([stall, ok, {csw, 18, 0}]),
    %% A sense that is read and names neither NOT READY nor UNIT ATTENTION keeps the medium.
    {_, Kept, []} = run(Ready, [{request, w, Ref, Write}],
                        Failing ++ [{data, sense_bytes(16#70, ?MEDIUM_ERROR, 16#11, 0)}, {csw, 0, 0}]),
    ?assertEqual([{error, {device, {sense, ?MEDIUM_ERROR, 16#11, 0}}}], replies(Kept)),
    ?assertNot(lists:keymember(medium_ended, 1, Kept)).

a_medium_is_ready_only_once_its_synchronize_cache_answers_test() ->
    {Flushing, Ref} = ready(started(), 0, true),
    {_, Flushed, []} = run(Flushing, [{request, f, Ref, {flush, 0}}], [ok, {csw, 0, 0}]),
    ?assertEqual([ok], replies(Flushed)),
    %% ILLEGAL REQUEST makes a medium that cannot flush; its flush is refused unsent.
    {NoFlush, Ref2} = ready(started(), 0, false),
    ?assertMatch({_, [{answer, f, {error, no_flush}}]}, step({request, f, Ref2, {flush, 0}}, NoFlush)),
    %% Any other sense leaves the unit without a medium.
    Other = make_ref(),
    {NotReady, Actions, []} = run(started(), [{request, r, none, {ready, 0, Other}}],
                                  [ok, {csw, 0, 1}, ok, {data, sense_bytes(16#70, ?NOT_READY, 16#3a, 0)},
                                   {csw, 0, 0}]),
    ?assertEqual([{error, {device, {sense, ?NOT_READY, 16#3a, 0}}}], replies(Actions)),
    ?assertMatch({_, [{answer, w, {error, {device, gone}}}]},
                 step({request, w, Other, {write, 0, 0, <<1>>}}, NotReady)).

a_request_of_an_ended_medium_is_answered_gone_unsent_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    ?assertMatch({_, [{medium_ended, 0, Ref}]}, step({end_medium, 0, Ref}, Ready)),
    {Ended, _} = step({end_medium, 0, Ref}, Ready),
    ?assertMatch({_, []}, step({end_medium, 0, Ref}, Ended)),
    ?assertMatch({_, [{answer, r, {error, {device, gone}}}]}, step({request, r, Ref, {read, 0, 0, 1}}, Ended)),
    %% A request for no medium is refused once the unit has one.
    ?assertMatch({_, [{answer, t, {error, {device, gone}}}]}, step({request, t, none, {test_unit_ready, 0}}, Ready)).

a_read_succeeds_only_whole_test() ->
    Read = {read, 1, 9, 2},
    Data = binary:copy(<<7>>, 1024),
    {Ready1, Ref1} = ready(started(), 1, true),
    %% A write is ok only with every byte moved, whatever the residue says.
    Write = {write, 1, 9, Data},
    {_, Short, []} = run(Ready1, [{request, w, Ref1, Write}], [ok, {moved, 1023}, {csw, 0, 0}]),
    ?assertEqual([{error, {device, short}}], replies(Short)),
    %% Media requests need their medium: none names no medium, and a readiness needs a
    %% unit without one.
    ?assertMatch({_, [{answer, n, {error, {device, gone}}}]}, step({request, n, none, Read}, started())),
    ?assertMatch({_, [{answer, n, {error, {device, gone}}}]}, step({request, n, Ref1, {ready, 1, make_ref()}}, Ready1)),
    Answer = fun(Script) ->
                     {_, Actions, []} = run(Ready1, [{request, r, Ref1, Read}], [ok | Script]),
                     replies(Actions)
             end,
    ?assertEqual([{ok, Data}], Answer([{data, Data}, {csw, 0, 0}])),
    ?assertEqual([{error, {device, short}}], Answer([{data, Data}, {csw, 512, 0}])),
    ?assertEqual([{error, {device, short}}], Answer([{data, binary:part(Data, 0, 512)}, {csw, 0, 0}])),
    ?assertEqual([{error, {device, reset}}], Answer([{data, Data}, {csw, 1025, 0}, ok, ok, ok])),
    ?assertEqual({in, 1024}, erx_usb_bot_core:data_phase(Read)).

the_deadlines_are_the_cores_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    %% A request queued 10 s is answered without being sent.
    {Busy, [{command, Tag, _}]} = step({request, a, Ref, {test_unit_ready, 0}}, Ready),
    {Queued, []} = erx_usb_bot_core:step({request, b, Ref, {test_unit_ready, 0}}, 1000, Busy),
    ?assertEqual(11000, erx_usb_bot_core:deadline(Queued)),
    ?assertMatch({_, []}, erx_usb_bot_core:step(tick, 10999, Queued)),
    {Swept, [{answer, b, {error, {device, deadline}}}]} = erx_usb_bot_core:step(tick, 11000, Queued),
    %% One issued 18 s ago ends its medium and starts reset recovery at once; the late
    %% completion of its transfer is ignored.
    {Abandoned, Actions} = erx_usb_bot_core:step(tick, 18000, Swept),
    ?assertEqual([{answer, a, {error, {device, deadline}}}, {medium_ended, 0, Ref}, class_reset], Actions),
    ?assertEqual(infinity, erx_usb_bot_core:deadline(Abandoned)),
    {Late, []} = erx_usb_bot_core:step({transfer, Tag, {error, stopped}}, 18001, Abandoned),
    %% One that ends past its deadline through reset recovery's own calls is answered the
    %% same, and another reset recovery comes before the next command.
    {Slow, Slower} = ready(started(), 0, true),
    {S1, [{command, T, _}]} = step({request, s, Slower, {test_unit_ready, 0}}, Slow),
    {S2, [{status, T}]} = step({transfer, T, {ok, 31}}, S1),
    {S3, [class_reset]} = erx_usb_bot_core:step({transfer, T, {ok, csw(T, 0, 2)}}, 17000, S2),
    {S4, [{reset_pipe, in}]} = erx_usb_bot_core:step({control, {ok, <<>>}}, 17000, S3),
    {S5, [{reset_pipe, out}]} = erx_usb_bot_core:step({reset_pipe, ok}, 17500, S4),
    ?assertMatch({_, [{answer, s, {error, {device, deadline}}}, {medium_ended, 0, Slower}, class_reset]},
                 erx_usb_bot_core:step({reset_pipe, ok}, 18000, S5)),
    {Idle, _, []} = run(Late, [{control, {ok, <<>>}}], [ok, ok]),
    ?assertMatch({_, [{command, _, {test_unit_ready, 0}}]}, step({request, c, none, {test_unit_ready, 0}}, Idle)),
    %% A request that reaches the head of the queue past its deadline is not sent either.
    {Busy2, [{command, Tag2, _}]} = step({request, d, none, {test_unit_ready, 1}}, started()),
    {Waiting, []} = step({request, e, none, {test_unit_ready, 1}}, Busy2),
    {Sent, [{status, Tag2}]} = erx_usb_bot_core:step({transfer, Tag2, {ok, 31}}, 5000, Waiting),
    {_, Finished} = erx_usb_bot_core:step({transfer, Tag2, {ok, csw(Tag2, 0, 0)}}, 12000, Sent),
    ?assertEqual([{answer, d, ok}, {answer, e, {error, {device, deadline}}}], Finished).

the_start_runs_reset_recovery_before_get_max_lun_test() ->
    {S1, [class_reset]} = step(start, erx_usb_bot_core:new()),
    %% A request waits for the units.
    {S2, []} = step({request, early, none, {inquiry, 0}}, S1),
    {S3, [{reset_pipe, in}]} = step({control, {ok, <<>>}}, S2),
    {S4, [{reset_pipe, out}]} = step({reset_pipe, ok}, S3),
    {S5, [get_max_lun]} = step({reset_pipe, ok}, S4),
    ?assertMatch({_, [{units, 1}, {command, _, {inquiry, 0}}]}, step({control, {error, stall}}, S5)),
    ?assertMatch({_, [{stop, {max_lun, 16}}]}, step({control, {ok, <<16>>}}, S5)),
    ?assertMatch({_, [{stop, {reset, stall}}]}, step({control, {error, stall}}, S1)),
    ?assertMatch({_, [{stop, {reset, gone}}]}, step({reset_pipe, {error, gone}}, S3)),
    ?assertMatch({_, [{stop, {reset, gone}}]}, step({reset_pipe, {error, gone}}, S4)).

%% ---------------------------------------------------------------------------------------
%% The decoders.

a_csw_is_valid_and_meaningful_as_bot_says_test() ->
    Csw = fun erx_usb_bot_core:csw/3,
    ?assertEqual({good, 0}, Csw(csw(5, 0, 0), 5, 36)),
    ?assertEqual({failed, 36}, Csw(csw(5, 36, 1), 5, 36)),
    ?assertEqual(not_meaningful, Csw(csw(5, 37, 0), 5, 36)),
    ?assertEqual(not_meaningful, Csw(csw(5, 37, 1), 5, 36)),
    ?assertEqual(not_meaningful, Csw(csw(5, 0, 3), 5, 36)),
    ?assertEqual(phase_error, Csw(csw(5, 16#ffffffff, 2), 5, 36)),
    ?assertEqual(invalid, Csw(csw(6, 0, 0), 5, 36)),
    ?assertEqual(invalid, Csw(<<16#55534243:32/little, 5:32/little, 0:32, 0>>, 5, 36)),
    ?assertEqual(invalid, Csw(<<(csw(5, 0, 0))/binary, 0>>, 5, 36)),
    ?assertEqual(invalid, Csw(binary:part(csw(5, 0, 0), 0, 12), 5, 36)).

get_max_lun_names_the_units_test() ->
    Max = fun erx_usb_bot_core:max_lun/1,
    ?assertEqual([{ok, 1}, {ok, 2}, {ok, 16}, {error, {max_lun, 16}}, {error, {max_lun, 255}}],
                 [Max({ok, <<N>>}) || N <- [0, 1, 15, 16, 255]]),
    ?assertEqual([{ok, 1}, {ok, 1}, {ok, 1}], [Max(A) || A <- [{error, stall}, {ok, <<>>}, {ok, <<1, 2>>}]]).

the_scsi_decoders_take_their_relevant_bytes_test() ->
    ?assertEqual({error, short}, erx_usb_bot_core:inquiry(inquiry_bytes(4))),
    ?assertEqual({ok, #{type => 0, qualifier => 0, removable => true}}, erx_usb_bot_core:inquiry(inquiry_bytes(31))),
    ?assertEqual({ok, #{type => 5, qualifier => 3, removable => false}},
                 erx_usb_bot_core:inquiry(<<16#65, 16#7f, 0, 0, 0>>)),
    ?assertEqual({error, short}, erx_usb_bot_core:sense(binary:part(sense_bytes(16#70, 6, 16#28, 1), 0, 13))),
    ?assertEqual({ok, {6, 16#28, 1}}, erx_usb_bot_core:sense(binary:part(sense_bytes(16#f0, 16#f6, 16#28, 1), 0, 14))),
    ?assertEqual({ok, {3, 1, 2}}, erx_usb_bot_core:sense(sense_bytes(16#71, 3, 1, 2))),
    ?assertEqual({error, unknown_format}, erx_usb_bot_core:sense(sense_bytes(16#72, 3, 1, 2))),
    ?assertEqual({ok, #{last_block => 16#ffffffff, block_length => 512}},
                 erx_usb_bot_core:read_capacity_10(<<16#ffffffff:32, 512:32>>)),
    ?assertEqual({error, short}, erx_usb_bot_core:read_capacity_10(<<1:32, 2:24>>)),
    ?assertEqual({ok, #{last_block => 16#100000000, block_length => 4096}},
                 erx_usb_bot_core:read_capacity_16(<<16#100000000:64, 4096:32>>)),
    ?assertEqual({error, short}, erx_usb_bot_core:read_capacity_16(<<1:64, 2:24>>)).

%% ---------------------------------------------------------------------------------------
%% Helpers.

step(Event, State) -> erx_usb_bot_core:step(Event, 0, State).

%% An engine started with Get Max LUN naming two units.
started() ->
    {State, _Actions, []} = run(erx_usb_bot_core:new(), [start], [ok, ok, ok, {max_lun, <<1>>}]),
    State.

%% Unit Lun given a medium, one that flushes or one whose readiness drew ILLEGAL REQUEST.
ready(State, Lun, Flush) ->
    Ref = make_ref(),
    Script = case Flush of
                 true -> [ok, {csw, 0, 0}];
                 false -> [ok, {csw, 0, 1}, ok, {data, sense_bytes(16#70, ?ILLEGAL_REQUEST, 16#20, 0)}, {csw, 0, 0}]
             end,
    {Ready, Actions, []} = run(State, [{request, ready, none, {ready, Lun, Ref}}], Script),
    [{ok, #{flush := Flush}}] = replies(Actions),
    {Ready, Ref}.

%% Steps Events, then answers each transfer the engine asks for from Script, in order, at
%% time 0; returns the state, every action, and what is left of Script.
run(State, Events, Script) ->
    {S, Actions} = lists:foldl(fun(Event, {S0, As}) ->
                                       {S1, New} = step(Event, S0),
                                       {S1, As ++ New}
                               end, {State, []}, Events),
    answer(S, Actions, Actions, Script).

answer(State, [], All, Script) ->
    {State, All, Script};
answer(State, [Action | Rest], All, Script) ->
    case {transfer(Action), Script} of
        {true, [Reply | Left]} ->
            {Next, New} = step(event(Action, Reply), State),
            answer(Next, Rest ++ New, All ++ New, Left);
        {_Output, _Script} ->
            answer(State, Rest, All, Script)
    end.

transfer(Action) ->
    lists:member(Action, [class_reset, get_max_lun])
        orelse lists:member(element(1, Action), [reset_pipe, command, data_in, data_out, status]).

event(class_reset, ok) -> {control, {ok, <<>>}};
event(get_max_lun, {max_lun, Bytes}) -> {control, {ok, Bytes}};
event({reset_pipe, _Pipe}, ok) -> {reset_pipe, ok};
event({command, Tag, _Command}, ok) -> {transfer, Tag, {ok, 31}};
event({data_in, Tag, _Length}, {data, Bytes}) -> {transfer, Tag, {ok, Bytes}};
event({data_out, Tag, _Command}, {moved, Moved}) -> {transfer, Tag, {ok, Moved}};
event({status, Tag}, {csw, Residue, Status}) -> {transfer, Tag, {ok, csw(Tag, Residue, Status)}};
event({status, Tag}, {raw, Bytes}) -> {transfer, Tag, {ok, Bytes}};
event({_Bulk, Tag, _}, stall) -> {transfer, Tag, {error, stall}};
event({status, Tag}, stall) -> {transfer, Tag, {error, stall}}.

replies(Actions) -> [Reply || {answer, _Id, Reply} <- Actions].

csw(Tag, Residue, Status) ->
    <<?CSW_SIGNATURE:32/little, Tag:32/little, Residue:32/little, Status>>.

sense_bytes(Code, Key) -> sense_bytes(Code, Key, 0, 0).

%% Fixed-format sense data of 18 bytes: response code, key in byte 2, ASC and ASCQ in
%% bytes 12 and 13, the additional length 10.
sense_bytes(Code, Key, Asc, Ascq) ->
    <<Code, 0, Key, 0:32, 10, 0:32, Asc, Ascq, 0, 0:24>>.

%% The first Length bytes of a removable direct-access unit's INQUIRY data.
inquiry_bytes(Length) ->
    binary:part(<<0, 16#80, 2, 2, 31, 0, 0, 0, "erXos   ", "test stick      ", "1.00">>, 0, Length).
