%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_hid_core, the HID function's fold (docs/design-usb.md, "Fuzz
%% targets"): a report against a layout taken from the corpus. Each round takes a layout
%% erx_hid_desc accepts, from the descriptor target's generator or a fixture, and folds
%% reports into it: reports of every id it has and of others, of its lengths and around
%% them, of random bytes and of values at the ends of each field. A round fails with a
%% marker the runner looks for: `crash` when step/3 raises; `out_of_bounds` when a record
%% is outside erx_input_codec:valid/1's bounds; `edge` when a key goes down while held or
%% up while not, against the held set the target tracks from the records; and
%% `state_grew` when an id's held set holds more codes than its fields have values.
-module(erx_hid_core_fuzz).

-export([run/1]).

-define(LAYOUTS, 3000).
-define(REPORTS, 30).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Records = lists:sum([layout_round(layout()) || _ <- lists:seq(1, ?LAYOUTS)]),
    io:format("fuzz: ~b rounds ok, ~b accepted~n", [?LAYOUTS, Records]).

%% A layout with at least one report: a fixture one time in four, else a generated one.
layout() ->
    Bytes = case rand:uniform(4) of
                1 -> lists:nth(rand:uniform(4), fixtures());
                _ -> erx_hid_desc_fuzz:descriptor()
            end,
    case erx_hid_desc:parse(Bytes) of
        {ok, Layout = #{reports := Reports}} when map_size(Reports) > 0 -> Layout;
        _ -> layout()
    end.

fixtures() ->
    T = erx_hid_desc_tests,
    [T:boot_keyboard(), T:boot_mouse(), T:tablet(),
     iolist_to_binary([T:usage_page(1), T:usage(16#38), T:usage(16#30), T:usage(16#31),
                       T:logical_min(-32768), T:logical_max(32767), T:report_size(16), T:report_count(3),
                       T:input(6)])].

layout_round(Layout) ->
    {_, _, Count} = lists:foldl(fun(_, {State, Held, N}) -> step(Layout, report(Layout), State, Held, N) end,
                                {erx_hid_core:new(Layout), [], 0}, lists:seq(1, ?REPORTS)),
    Count.

step(Layout, Report, State, Held, N) ->
    {Records, Next} = try erx_hid_core:step(Layout, Report, State)
                      catch Class:Reason:Stack -> fail(crash, Layout, Report, {Class, Reason, Stack})
                      end,
    [fail(out_of_bounds, Layout, Report, Record) || Record <- Records, not erx_input_codec:valid(Record)],
    bounded(Layout, Next, Report),
    {Next, lists:foldl(fun(Record, H) -> edge(Record, H, Layout, Report) end, Held, Records), N + length(Records)}.

edge({key, down, Code}, Held, Layout, Report) ->
    lists:member(Code, Held) andalso fail(edge, Layout, Report, {down, Code}),
    [Code | Held];
edge({key, up, Code}, Held, Layout, Report) ->
    lists:member(Code, Held) orelse fail(edge, Layout, Report, {up, Code}),
    lists:delete(Code, Held);
edge(_, Held, _, _) ->
    Held.

%% The state is opaque to callers; this test alone reads its representation, a map of
%% entries by id, to bound the held sets by the fields that set them.
bounded(#{reports := Reports}, State, Report) ->
    #{entries := Entries} = State,
    map_size(Entries) =:= map_size(Reports) orelse fail(state_grew, Reports, Report, State),
    [fail(state_grew, Reports, Report, State)
     || Id := #{held := Held} <- Entries,
        length(Held) > lists:sum([C || #{count := C} <- maps:get(fields, maps:get(Id, Reports))])].

report(#{reports := Reports, numbered := Numbered}) ->
    Ids = maps:keys(Reports),
    Id = case rand:uniform(10) of 1 -> rand:uniform(256) - 1; _ -> lists:nth(rand:uniform(length(Ids)), Ids) end,
    Bytes = case Reports of #{Id := #{bytes := B}} -> B; _ -> rand:uniform(8) end,
    Length = max(0, Bytes + pick([0, 0, 0, -1, 1, -Bytes])),
    Body = case rand:uniform(3) of
               1 -> rand:bytes(Length);
               2 -> binary:copy(<<(pick([0, 1, 16#ff, 16#80, 16#7f]))>>, Length);
               3 -> << <<(pick([0, 0, 0, 1, 4, 5, 16#e0, 16#ff]))>> || _ <- lists:seq(1, Length) >>
           end,
    case Numbered of
        true -> <<Id, Body/binary>>;
        false -> Body
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

fail(Marker, Layout, Report, Detail) ->
    io:format("~s: ~p~n layout ~p~n report ~p~n", [Marker, Detail, Layout, Report]),
    halt(1).
