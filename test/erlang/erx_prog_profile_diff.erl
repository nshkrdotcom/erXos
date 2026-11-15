%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The Erlang side of the program protocol's differential test
%% (test/host/prog_profile_test.rb, docs/design-abi.md#program-protocol).
%% corpus/1 writes frames the builders make from values up to every bound,
%% and one mutation per rule of the table, each with the refusal it must
%% draw; judge/1 gives this side's verdict on each frame: the frame bound,
%% then binary_to_term(Bytes, [safe, used]) reading all of it, then the
%% grammar. A decode failure or a Used short of the frame is malformed.
-module(erx_prog_profile_diff).

-export([corpus/1, judge/1, judge_ignoring_used/1]).

-define(FRAME_MAX, 196608).
-define(ARGS_MAX, 131072).

%% Writes Dir/requests ("FRAME full [BUSY] HEX" lines, BUSY for a reply or to_program
%% frame: its busy slots as SLOT:CASE pairs joined by commas, or "-") and Dir/expected
%% (accept, or REASON KIND for a single-rule mutation).
corpus([Dir]) ->
    Cases = valid() ++ pipe_valid() ++ request_valid() ++ mutations() ++ pipe_mutations() ++ request_mutations(),
    Lines = lists:map(fun encode/1, Cases),
    ok = file:write_file(filename:join(Dir, "requests"),
                         [[atom_to_list(Frame), " full ", busy_word(Frame, Busy), hex(Bytes), "\n"]
                          || {Frame, Busy, Bytes, _} <- Lines]),
    ok = file:write_file(filename:join(Dir, "expected"),
                         [[Expected, "\n"] || {_, _, _, Expected} <- Lines]),
    halt(0).

%% Reads Dir/judge ("FRAME [BUSY] HEX [CHEX]" lines) and writes Dir/verdicts: this side's verdict,
%% then "same" when CHEX, the C driver's rewrite of an accepted frame, decodes to the
%% same term, or "differs".
judge(Dir) ->
    judge(Dir, true).

%% The seeded fault of the test: a side that takes a term however much of the frame it used.
judge_ignoring_used(Dir) ->
    judge(Dir, false).

judge([Dir], Used) ->
    put(used, Used),
    {ok, Text} = file:read_file(filename:join(Dir, "judge")),
    Lines = [binary:split(Line, <<" ">>, [global]) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])],
    Verdicts = [verdict(Line) || Line <- Lines],
    ok = file:write_file(filename:join(Dir, "verdicts"), [[V, "\n"] || V <- Verdicts]),
    halt(0).

verdict([FrameName | Words]) ->
    Frame = binary_to_atom(FrameName),
    {Busy, [Hex | Rewrite]} = case takes_busy(Frame) of
                                  true -> {busy(hd(Words)), tl(Words)};
                                  false -> {#{}, Words}
                              end,
    Bytes = binary:decode_hex(Hex),
    Verdict = side(Frame, Busy, Bytes),
    case {Verdict, Rewrite} of
        {"accepted", [C]} ->
            Same = (catch binary_to_term(binary:decode_hex(C))) =:= binary_to_term(Bytes),
            Verdict ++ if Same -> " same"; true -> " differs" end;
        _ ->
            Verdict
    end.

takes_busy(Frame) -> Frame =:= reply orelse Frame =:= to_program.

%% A BUSY word as the map check_reply/2 and check_to_program/2 take.
busy(<<"-">>) ->
    #{};
busy(Word) ->
    maps:from_list([{binary_to_integer(Slot), binary_to_atom(Case)}
                    || Pair <- binary:split(Word, <<",">>, [global]), [Slot, Case] <- [binary:split(Pair, <<":">>)]]).

busy_word(Frame, Busy) ->
    case takes_busy(Frame) of
        true when map_size(Busy) =:= 0 -> "- ";
        true -> [lists:join(",", [[integer_to_list(Slot), ":", atom_to_list(Case)] || {Slot, Case} <- maps:to_list(Busy)]), " "];
        false -> ""
    end.

side(Frame, _, Bytes) when byte_size(Bytes) > ?FRAME_MAX ->
    refused(size, Frame);
side(Frame, Busy, Bytes) ->
    Strict = get(used) =/= false,
    try binary_to_term(Bytes, [safe, used]) of
        {Term, Used} when Used =:= byte_size(Bytes); not Strict -> answer(check(Frame, Term, Busy));
        _ -> refused(malformed, Frame)
    catch
        error:badarg -> refused(malformed, Frame)
    end.

check(start, Term, _) -> erx_prog_grammar:check_start(Term);
check(request, Term, _) -> erx_prog_grammar:check_request(Term);
check(notice, Term, _) -> erx_prog_grammar:check_notice(Term);
check(report, Term, _) -> erx_prog_grammar:check_report(Term);
check(reply, Term, Busy) -> erx_prog_grammar:check_reply(Term, Busy);
check(to_program, Term, Busy) -> erx_prog_grammar:check_to_program(Term, Busy).

answer(ok) -> "accepted";
answer({error, {Reason, Kind}}) -> refused(Reason, Kind).

refused(Reason, Kind) -> lists:flatten(["refused ", atom_to_list(Reason), " ", atom_to_list(Kind)]).

encode({Name, {frame, Frame, Term}, Expected}) ->
    encode({Name, {bytes, Frame, term_to_binary(Term)}, Expected});
encode({Name, {frame, Frame, Busy, Term}, Expected}) ->
    encode({Name, {bytes, Frame, Busy, term_to_binary(Term)}, Expected});
encode({Name, {bytes, Frame, Bytes}, Expected}) ->
    encode({Name, {bytes, Frame, #{}, Bytes}, Expected});
encode({_Name, {bytes, Frame, Busy, Bytes}, Expected}) ->
    {Frame, Busy, Bytes, Expected};
encode({Name, {value, Value}, Expected}) ->
    %% A mutation is built unchecked, its lists sorted as a builder would, so it breaks its one rule.
    {ok, Sorted} = sorted(Value),
    encode({Name, {frame, start, Sorted}, Expected}).

sorted(Value) ->
    case erx_prog_grammar:build_start(Value) of
        {ok, Frame} -> {ok, Frame};
        {error, _} -> {ok, {erx_start, 1, Value}}
    end.

hex(Bytes) -> binary:encode_hex(Bytes, lowercase).

%% The values every rule accepts, from the least to each bound.
base() ->
    #{pid => 2, ppid => 1, pgid => 2,
      argv => [<<"prog">>, <<"a">>], env => [<<"HOME=/">>], cwd => <<"/home/u">>,
      spawn => true, sigmask => [sigint, sigterm], sigignore => [],
      umask => 8#022, data_area => {100, 4},
      fds => [{0, {tty, 1, read}}, {1, {tty, 1, write}}, {2, {dup, 1}},
              {3, {pipe, write, {1, 2}, #{wend => 1, ring => 101, rpage => 102, size => 16384,
                                         readers => [{0, 103}]}}},
              {4, {pipe, read, {2, 3}, #{rix => 0, lock => 104, wends => 2,
                                        writers => [{1, 105, 106, 65536, {open, 107}},
                                                    {2, 112, 113, 16384, gone}],
                                        readers => []}}},
              {5, {socketpair, {3, 1}, #{rix => 1, lock => 108, wends => 2, writers => [], readers => [{0, 109}]},
                   {4, 1}, #{wend => 2, ring => 110, rpage => 111, size => 65536, readers => []}}},
              {6, {file, 7, read_write}}, {7, {dir, 8}}, {8, {socket, 9}}, {9, null}, {10, {mem, 16, 2}}],
      image => {object, 16#ffffffffffffff00}}.

valid() ->
    Base = base(),
    Arg = binary:copy(<<"a">>, ?ARGS_MAX - 1),
    Cwd = <<"/", (binary:copy(<<"c">>, 4095))/binary>>,
    Fds = [{N, null} || N <- lists:seq(0, 1023)],
    [built(base, Base),
     built(no_image, maps:remove(image, Base)),
     built(args_at_total, Base#{argv => [Arg], env => []}),
     built(cwd_at_max, Base#{cwd => Cwd}),
     built(root, Base#{cwd => <<"/">>}),
     built(fds_at_max, Base#{fds => Fds}),
     built(unsorted, Base#{sigmask => [sigterm, sigint], fds => lists:reverse(maps:get(fds, Base))})].

%% Base with the read end of fd 4 naming Writers.
writers(#{fds := Fds} = Base, Writers) ->
    {4, {pipe, read, PipeEnd, R}} = lists:keyfind(4, 1, Fds),
    Base#{fds := lists:keyreplace(4, 1, Fds, {4, {pipe, read, PipeEnd, R#{writers := Writers}}})}.

built(Name, Value) ->
    {ok, Frame} = erx_prog_grammar:build_start(Value),
    {Name, {frame, start, Frame}, "accept"}.

mutations() ->
    B = base(),
    Fds = maps:get(fds, B),
    Valid = term_to_binary(element(2, erx_prog_grammar:build_start(B))),
    [{arg_past_max, {value, B#{argv => [binary:copy(<<"a">>, ?ARGS_MAX + 1)]}}, "length arg"},
     {cwd_past_max, {value, B#{cwd => <<"/", (binary:copy(<<"c">>, 4096))/binary>>}}, "length cwd"},
     {fds_past_max, {value, B#{fds => [{N, null} || N <- lists:seq(0, 1024)]}}, "length fds"},
     {key_missing, {value, maps:remove(umask, B)}, "key start"},
     {key_unknown, {value, B#{erlang => 1}}, "key start"},
     {fds_out_of_order, {frame, start, {erx_start, 1, B#{fds => [lists:nth(2, Fds), hd(Fds) | tl(tl(Fds))]}}},
      "order fds"},
     {signals_out_of_order, {frame, start, {erx_start, 1, B#{sigmask => [sigterm, sigint]}}}, "order signals"},
     {signal_repeated, {value, B#{sigmask => [sigint, sigint]}}, "order signals"},
     {no_case, {value, B#{fds => lists:keyreplace(9, 1, Fds, {9, erlang})}}, "no_case descriptor"},
     {cap_repeated, {value, B#{data_area => {101, 4}}}, "unique cap"},
     {dup_of_dup, {value, B#{fds => Fds ++ [{11, {dup, 2}}]}}, "refers dup_target"},
     {dup_of_absent, {value, B#{fds => lists:keyreplace(2, 1, Fds, {2, {dup, 11}})}}, "refers dup_target"},
     {invalid_utf8, {value, B#{argv => [<<255>>]}}, "utf8 arg"},
     {zero_byte, {value, B#{argv => [<<"a", 0>>]}}, "text arg"},
     {env_without_name, {value, B#{env => [<<"=x">>]}}, "text env_var"},
     {env_without_assign, {value, B#{env => [<<"x">>]}}, "text env_var"},
     {cwd_relative, {value, B#{cwd => <<"a/b">>}}, "text cwd"},
     {cwd_dotdot, {value, B#{cwd => <<"/a/../b">>}}, "text cwd"},
     {cwd_trailing, {value, B#{cwd => <<"/a/">>}}, "text cwd"},
     {total_by_one, {value, B#{argv => [binary:copy(<<"a">>, ?ARGS_MAX)], env => []}}, "total args"},
     {umask_range, {value, B#{umask => 512}}, "range umask"},
     {pid_range, {value, B#{pid => 1}}, "range process_id"},
     {lane_size, {value, B#{fds => lists:keyreplace(3, 1, Fds, {3, {pipe, write, {1, 2},
                                 #{wend => 1, ring => 101, rpage => 102, size => 1000, readers => []}}})}},
      "range lane_size"},
     {cap_null, {value, B#{data_area => {0, 4}}}, "range cap"},
     %% Only an open writer carries its doorbell.
     {gone_writer_doorbell,
      {value, writers(B, [{1, 105, 106, 65536, {open, 107}}, {2, 112, 113, 16384, {gone, 114}}])},
      "no_case writer_state"},
     {open_writer_no_doorbell, {value, writers(B, [{1, 105, 106, 65536, open}])}, "no_case writer_state"},
     {spawn_shape, {value, B#{spawn => undefined}}, "shape boolean"},
     {signal_unknown, {value, B#{sigmask => [ok]}}, "range signal"},
     {improper_list, {frame, start, {erx_start, 1, B#{argv => [<<"a">> | <<"b">>]}}}, "shape argv"},
     {version, {frame, start, {erx_start, 2, B}}, "version start"},
     {tag, {frame, start, {erx_prog, 1, B}}, "shape start"},
     {frame_over_bound, {bytes, start, <<Valid/binary, (binary:copy(<<0>>, ?FRAME_MAX + 1 - byte_size(Valid)))/binary>>},
      "size start"},
     {byte_after, {bytes, start, <<Valid/binary, 0>>}, "malformed start"},
     %% No term holds a map key twice, so the repeated key is made in the bytes: ppid becomes
     %% pgid, from a frame whose ppid is a valid pgid too.
     {key_repeated, {bytes, start, binary:replace(term_to_binary(element(2, erx_prog_grammar:build_start(B#{ppid => 2}))),
                                                  <<119, 4, "ppid">>, <<119, 4, "pgid">>)},
      "malformed start"},
     {request_no_case, {frame, request, {erx_prog, 1, 0, ok}}, "no_case request"},
     {request_slot, {frame, request, {erx_prog, 1, 16, ok}}, "range slot"}].

%% Notices and reports, one of each case, with each integer at its least and at its bound.
pipe_valid() ->
    Max = 16#ffffffff,
    [notice(closed_least, {closed, 1, 1}),
     notice(closed_max, {closed, Max, Max}),
     notice(drained, {drained, 1, Max, Max}),
     report(writer_open, {pipe_writer, 1, 1, 1, 1, 2, 16384, 3, open}),
     report(writer_state_gone_max, {pipe_writer, Max, Max, Max, 16#ffffffffffffffff, 16#8000000000000000, 65536,
                          16#7fffffffffffffff, gone}),
     report(writer_gone, {pipe_writer_gone, 1, Max, Max}),
     report(reader_least, {pipe_reader, 1, 1, 0, 1, open}),
     report(reader_max, {pipe_reader, Max, Max, 63, 16#ffffffffffffffff, gone}),
     report(reader_gone, {pipe_reader_gone, 1, Max, 63}),
     report(lost, {pipe_lost, Max, 1}),
     report(server_lost, pipe_server_lost)].

notice(Name, Value) ->
    {ok, Frame} = erx_prog_grammar:build_notice(Value),
    {Name, {frame, notice, Frame}, "accept"}.

report(Name, Value) ->
    {ok, Frame} = erx_prog_grammar:build_report(Value),
    {Name, {frame, report, Frame}, "accept"}.

%% One mutation for each rule of the notices and reports, each with the refusal it must draw.
pipe_mutations() ->
    Writer = {pipe_writer, 1, 2, 3, 101, 102, 16384, 103, open},
    [{closed_as_request, {frame, request, {erx_prog, 1, {closed, 1, 1}}}, "shape request"},
     {closed_pipe_zero, {frame, notice, {erx_prog, 1, {closed, 0, 1}}}, "range pipe_id"},
     {closed_end_zero, {frame, notice, {erx_prog, 1, {closed, 1, 0}}}, "range end_id"},
     {closed_end_past_u32, {frame, notice, {erx_prog, 1, {closed, 1, 16#100000000}}}, "range end_id"},
     {drained_writer_zero, {frame, notice, {erx_prog, 1, {drained, 1, 1, 0}}}, "range wend"},
     {closed_arity, {frame, notice, {erx_prog, 1, {closed, 1, 1, 1, 1}}}, "no_case notice"},
     {closed_atom, {frame, notice, {erx_prog, 1, closed}}, "no_case notice"},
     {notice_report_case, {frame, notice, {erx_prog, 1, {pipe_lost, 1, 1}}}, "no_case notice"},
     {notice_version, {frame, notice, {erx_prog, 2, {closed, 1, 1}}}, "version notice"},
     {notice_slot, {frame, notice, {erx_prog, 1, 0, {closed, 1, 1}}}, "shape notice"},
     {notice_shape, {frame, notice, {erx_prog, 1, 1}}, "shape notice"},
     {writer_lane_size, {frame, report, {erx_prog, 1, setelement(7, Writer, 1000)}}, "range lane_size"},
     {writer_ring_rpage, {frame, report, {erx_prog, 1, setelement(6, Writer, 101)}}, "unique cap"},
     {writer_doorbell, {frame, report, {erx_prog, 1, setelement(8, Writer, 101)}}, "unique cap"},
     {writer_cap_null, {frame, report, {erx_prog, 1, setelement(5, Writer, 0)}}, "range cap"},
     {writer_end_state, {frame, report, {erx_prog, 1, setelement(9, Writer, closed)}}, "no_case end_state"},
     {reader_rix, {frame, report, {erx_prog, 1, {pipe_reader, 1, 1, 64, 101, open}}}, "range rix"},
     {reader_gone_rix, {frame, report, {erx_prog, 1, {pipe_reader_gone, 1, 1, 64}}}, "range rix"},
     {reader_doorbell_null, {frame, report, {erx_prog, 1, {pipe_reader, 1, 1, 0, 0, open}}}, "range cap"},
     {server_lost_tuple, {frame, report, {erx_prog, 1, {pipe_server_lost}}}, "no_case report"},
     {report_notice_case, {frame, report, {erx_prog, 1, {closed, 1, 1}}}, "no_case report"},
     {report_version, {frame, report, {erx_prog, 0, pipe_server_lost}}, "version report"},
     {report_tag, {frame, report, {erx_start, 1, pipe_server_lost}}, "shape report"}].

%% The busy slots of the replies: slot 3 holds a kill, slot 5 a probe, slot 6 an
%% lopen, slot 7 a read and slot 8 a clunk.
-define(BUSY, #{3 => kill, 5 => probe, 6 => file_lopen, 7 => file_read, 8 => file_clunk}).

%% Requests and their replies, each through its builder, and frames to the program
%% through check_to_program/2's dispatch: a report, and a reply on a busy slot.
request_valid() ->
    {ok, Report} = erx_prog_grammar:build_report(pipe_server_lost),
    {ok, Reply} = erx_prog_grammar:build_reply(kill, 3, {error, esrch}),
    [request(kill_least, 0, {kill, 2, sighup}),
     request(kill_max, 15, {kill, 16#7fffffff, 'sigrtmax'}),
     request(probe_least, 0, {probe, 2}),
     request(probe_max, 15, {probe, 16#7fffffff}),
     reply(kill_ok, kill, 3, ok),
     reply(kill_esrch, kill, 3, {error, esrch}),
     reply(kill_last_errno, kill, 3, {error, eintegrity}),
     reply(probe_ok, probe, 5, ok),
     reply(probe_esrch, probe, 5, {error, esrch}),
     request(lopen_least, 0, {file, lopen, <<>>, 0}),
     request(lopen_max, 15, {file, lopen, binary:copy(<<"a">>, 4096), 16#ffffffff}),
     request(lcreate_mode_max, 1, {file, lcreate, <<"/tmp/f">>, 1, 8#7777}),
     request(read_least, 2, {file, read, 0, 1, 0}),
     request(read_max, 2, {file, read, 16#ffff, 65536, 15}),
     request(write_max, 2, {file, write, 16#ffff, 65536, 15}),
     request(clunk_open, 3, {file, clunk, 7}),
     reply(lopen_ok, file_lopen, 6, {ok, 16#ffff}),
     reply(lopen_enoent, file_lopen, 6, {error, enoent}),
     reply(read_eof, file_read, 7, {ok, 0}),
     reply(read_full, file_read, 7, {ok, 65536}),
     reply(clunk_ok, file_clunk, 8, ok),
     {to_program_report, {frame, to_program, ?BUSY, Report}, "accept"},
     {to_program_reply, {frame, to_program, ?BUSY, Reply}, "accept"}].

request(Name, Slot, Value) ->
    {ok, Frame} = erx_prog_grammar:build_request(Slot, Value),
    {Name, {frame, request, Frame}, "accept"}.

reply(Name, Request, Slot, Value) ->
    {ok, Frame} = erx_prog_grammar:build_reply(Request, Slot, Value),
    {Name, {frame, reply, ?BUSY, Frame}, "accept"}.

%% One mutation for each rule of the requests and replies: a reply's slot must be busy
%% and its value the reply the request on that slot takes; an alias names no errno.
request_mutations() ->
    [{kill_signal_zero, {frame, request, {erx_prog, 1, 0, {kill, 2, 0}}}, "shape signal"},
     {kill_signal_unknown, {frame, request, {erx_prog, 1, 0, {kill, 2, sigfoo}}}, "range signal"},
     {kill_pid_one, {frame, request, {erx_prog, 1, 0, {kill, 1, sigint}}}, "range process_id"},
     {kill_arity, {frame, request, {erx_prog, 1, 0, {kill, 2}}}, "no_case request"},
     {probe_pid_one, {frame, request, {erx_prog, 1, 0, {probe, 1}}}, "range process_id"},
     {probe_signal, {frame, request, {erx_prog, 1, 0, {probe, 2, 0}}}, "no_case request"},
     {probe_atom, {frame, request, {erx_prog, 1, 0, probe}}, "no_case request"},
     {probe_reply_no_case, {frame, reply, ?BUSY, {erx_prog, 1, 5, {ok, 1}}}, "no_case probe_reply"},
     {reply_idle_slot, {frame, reply, ?BUSY, {erx_prog, 1, 4, ok}}, "range slot"},
     {reply_nothing_busy, {frame, reply, #{}, {erx_prog, 1, 3, ok}}, "range slot"},
     {reply_slot_past, {frame, reply, ?BUSY, {erx_prog, 1, 16, ok}}, "range slot"},
     {reply_slot_shape, {frame, reply, ?BUSY, {erx_prog, 1, kill, ok}}, "shape slot"},
     {reply_no_case, {frame, reply, ?BUSY, {erx_prog, 1, 3, {ok, 1}}}, "no_case kill_reply"},
     {reply_atom_case, {frame, reply, ?BUSY, {erx_prog, 1, 3, error}}, "no_case kill_reply"},
     {reply_errno_alias, {frame, reply, ?BUSY, {erx_prog, 1, 3, {error, eopnotsupp}}}, "range errno"},
     {reply_errno_shape, {frame, reply, ?BUSY, {erx_prog, 1, 3, {error, 95}}}, "shape errno"},
     {reply_version, {frame, reply, ?BUSY, {erx_prog, 2, 3, ok}}, "version reply"},
     {reply_without_slot, {frame, reply, ?BUSY, {erx_prog, 1, ok}}, "shape reply"},
     {reply_tag, {frame, reply, ?BUSY, {erx_start, 1, 3, ok}}, "shape reply"},
     {lopen_path_nul, {frame, request, {erx_prog, 1, 0, {file, lopen, <<"a", 0>>, 0}}}, "text file_path"},
     {lopen_path_long, {frame, request, {erx_prog, 1, 0, {file, lopen, binary:copy(<<"a">>, 4097), 0}}}, "length file_path"},
     {lcreate_mode_past, {frame, request, {erx_prog, 1, 0, {file, lcreate, <<"f">>, 0, 8#10000}}}, "range file_mode"},
     {read_count_zero, {frame, request, {erx_prog, 1, 0, {file, read, 0, 0, 0}}}, "range io_count"},
     {read_count_past, {frame, request, {erx_prog, 1, 0, {file, read, 0, 65537, 0}}}, "range io_count"},
     {write_slot_past, {frame, request, {erx_prog, 1, 0, {file, write, 0, 1, 16}}}, "range data_slot"},
     {file_unknown_op, {frame, request, {erx_prog, 1, 0, {file, mkdir, <<"d">>}}}, "no_case request"},
     {read_reply_past, {frame, reply, ?BUSY, {erx_prog, 1, 7, {ok, 65537}}}, "range io_done"},
     {lopen_reply_no_case, {frame, reply, ?BUSY, {erx_prog, 1, 6, ok}}, "no_case open_reply"},
     {clunk_reply_no_case, {frame, reply, ?BUSY, {erx_prog, 1, 8, {ok, 1}}}, "no_case clunk_reply"},
     {to_program_idle, {frame, to_program, #{}, {erx_prog, 1, 3, ok}}, "range slot"},
     {to_program_start, {frame, to_program, ?BUSY, {erx_start, 1, pipe_server_lost}}, "shape reply"},
     {to_program_report_case, {frame, to_program, ?BUSY, {erx_prog, 1, {pipe_lost, 0, 1}}}, "range pipe_id"}].
