%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_tty's set/2, size/3 and input/2, the line
%% discipline's readers of untrusted values, and of erx_abi_termios's
%% decode/1, which reads a program's struct termios (docs/design-live.md,
%% "The tty" and "Verification and testing"): random termios and structs,
%% valid and broken one way at a time; random window sizes; and random
%% bytes in random chunks, up to past the input bound, and runs of VREPRINT
%% after a long line, under random termios, between random reads, waits and
%% writes. Whatever arrives, nothing crashes, a valid termios is kept as
%% given and a broken one refused, what waits stays within 4 KiB, every
%% action is one of erx_tty's, nothing is echoed without ECHO or ECHONL but
%% a bell, one call echoes at most 16 KiB, input fed back until none is left
%% does what input a byte at a time does, and in raw mode with no flag that
%% changes or takes bytes, every byte is read, still waits or was counted
%% as dropped. The seed comes from
%% make check-fuzz; a failure is error({fuzz_failure, Property, Detail}).

-module(erx_tty_fuzz).
-export([run/1]).

-define(ROUNDS, 3000).
-define(MAX_INPUT, 4096).
%% The most one input/2 echoes (docs/design-live.md, "The tty").
-define(MAX_ECHO, 16384).
%% The tables of the ABI file's termios table.
-define(IFLAGS, erx_abi_termios:flags(iflag)).
-define(OFLAGS, erx_abi_termios:flags(oflag)).
-define(CFLAGS, erx_abi_termios:flags(cflag)).
-define(LFLAGS, erx_abi_termios:flags(lflag)).
-define(CHARS, erx_abi_termios:chars()).
%% Flags that change or take received bytes, which the count of bytes leaves out.
-define(TAKERS, [icrnl, igncr, inlcr, istrip, ixon, parmrk, isig, icanon]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    lists:foreach(fun(_) ->
                          termios_round(),
                          struct_round(),
                          size_round(),
                          input_round()
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

termios_round() ->
    Tty = erx_tty:new(),
    Valid = random_termios(),
    case erx_tty:set(Valid, Tty) of
        {ok, _, Set} ->
            Kept = erx_tty:termios(Set),
            check(Kept =:= normal(Valid), termios_not_kept, {Valid, Kept});
        {error, einval} ->
            fail(valid_refused, Valid)
    end,
    Broken = broken(Valid),
    check(erx_tty:set(Broken, Tty) =:= {error, einval}, invalid_accepted, Broken).

%% A C program's struct termios through erx_abi_termios, the program
%% protocol's codec: a valid one decodes to a termios set/2 keeps, which
%% encodes back to the struct less what the table does not name and decodes
%% to itself again; a broken one is refused.
struct_round() ->
    Struct = random_struct(),
    case erx_abi_termios:decode(Struct) of
        {ok, Termios} ->
            check(element(1, erx_tty:set(Termios, erx_tty:new())) =:= ok, decoded_refused, Struct),
            Encoded = erx_abi_termios:encode(Termios),
            check(within(Encoded, Struct), codec_added, {Struct, Encoded}),
            check(erx_abi_termios:decode(Encoded) =:= {ok, Termios}, codec_round_trip, Struct);
        {error, einval} ->
            fail(struct_refused, Struct)
    end,
    Broken = broken_struct(Struct),
    check(erx_abi_termios:decode(Broken) =:= {error, einval}, codec_invalid_accepted, Broken).

size_round() ->
    Tty = erx_tty:new(),
    Rows = pick([0, 1, 24, 65535, 65536, -1, 1.0, rows, rand:uniform(70000)]),
    Columns = pick([0, 1, 80, 65535, 65536, -5, "80", rand:uniform(70000)]),
    Valid = is_integer(Rows) andalso Rows >= 1 andalso Rows =< 65535 andalso
        is_integer(Columns) andalso Columns >= 1 andalso Columns =< 65535,
    case erx_tty:size(Rows, Columns, Tty) of
        {ok, Actions, Sized} when Valid ->
            Changed = {Rows, Columns} =/= {24, 80},
            check(Actions =:= [winch || Changed] andalso
                      erx_tty:winsize(Sized) =:= {Rows, Columns}, size_not_kept, {Rows, Columns});
        {error, einval} when not Valid ->
            ok;
        Other ->
            fail(size_checked_wrong, {Rows, Columns, Other})
    end.

input_round() ->
    Termios = random_termios(),
    {ok, _, Tty} = erx_tty:set(Termios, erx_tty:new()),
    Counted = [] =:= [F || F <- ?TAKERS, has(F, Termios)],
    steps(rand:uniform(12), Termios, Counted, Tty, {0, 0}).

%% Read and In count the bytes read and received, for the conservation check.
steps(0, _, _, _, _) ->
    ok;
steps(N, Termios, Counted, Tty, {Read, In}) ->
    case rand:uniform(4) of
        1 ->
            Bytes = random_input(Termios),
            check_chunked(Bytes, Termios, Tty),
            {Actions, Rest, Tty1} = erx_tty:input(Bytes, Tty),
            Taken = byte_size(Bytes) - byte_size(Rest),
            check_input(Actions, Rest, Termios, Tty, Tty1, Bytes),
            check(not Counted orelse
                      Read + erx_tty:waiting(Tty1) + erx_tty:dropped(Tty1) =:= In + Taken,
                  bytes_lost, {Termios, Bytes}),
            steps(N - 1, Termios, Counted, Tty1, {Read, In + Taken});
        2 ->
            {Got, Tty1} = erx_tty:read(r, rand:uniform(5000), Tty),
            Taken = case Got of
                        {ok, Bin} -> byte_size(Bin);
                        _ -> 0
                    end,
            steps(N - 1, Termios, Counted, Tty1, {Read + Taken, In});
        3 ->
            {Actions, Tty1} = erx_tty:read_wait(pick([r, s]), rand:uniform(4096), Tty),
            check_actions(Actions),
            steps(N - 1, Termios, Counted, Tty1, {Read, In});
        4 ->
            Room = rand:uniform(300) - 1,
            {Taken, Out, Tty1} = erx_tty:output(random_bytes(), Room, Tty),
            check(byte_size(Out) =< Room andalso Taken >= 0, output_over_room, {Room, Out}),
            steps(N - 1, Termios, Counted, Tty1, {Read, In})
    end.

%% Input stops only after a signal key, and returns a tail of its bytes.
check_input(Actions, Rest, Termios, Before, After, Bytes) ->
    check_actions(Actions),
    Taken = byte_size(Bytes) - byte_size(Rest),
    check(Taken > 0 orelse Bytes =:= <<>>, input_took_nothing, Bytes),
    check(binary:part(Bytes, Taken, byte_size(Rest)) =:= Rest,
          rest_not_a_tail, {Bytes, Rest}),
    Signals = length([S || {signal, S} <- Actions]),
    check(Rest =:= <<>> orelse Signals =:= 1, stopped_without_signal,
          {Termios, Bytes}),
    Keyed = binary:part(Bytes, 0, Taken - 1),
    check(Signals =:= 0 orelse not signals(Keyed, Before),
          went_past_a_signal, {Termios, Bytes}),
    Raw = not has(icanon, Termios),
    check(not Raw orelse erx_tty:waiting(After) =< ?MAX_INPUT, input_over_bound,
          {erx_tty:waiting(After), byte_size(Bytes)}),
    check(erx_tty:dropped(After) >= erx_tty:dropped(Before), dropped_went_back, Bytes),
    Echo = iolist_to_binary([E || {echo, E} <- Actions]),
    Quiet = not has(echo, Termios) andalso not has(echonl, Termios),
    check(not Quiet orelse Echo =:= binary:copy(<<7>>, byte_size(Echo)),
          echo_without_echo, {Termios, Bytes, Echo}),
    check(byte_size(Echo) =< ?MAX_ECHO, echo_over_bound, {Termios, byte_size(Echo)}).

%% With no reader waiting, input fed back until none is left gives the
%% state and the actions, neighbouring echoes joined, of input a byte at a
%% time, while that echoes no more than one call's bound. A waiting reader
%% is reported once per call, after its last key, so both are cancelled.
check_chunked(Bytes, Termios, Tty0) ->
    {_, Tty1} = erx_tty:cancel(r, Tty0),
    {_, Tty} = erx_tty:cancel(s, Tty1),
    {BytewiseActions, _} = Bytewise = fed([<<B>> || <<B>> <= Bytes], Tty),
    Echo = iolist_to_binary([E || {echo, E} <- BytewiseActions]),
    check(byte_size(Echo) > ?MAX_ECHO orelse fed([Bytes], Tty) =:= Bytewise,
          chunked_differs, {Termios, Bytes}).

%% Whether Bytes, fed back until none is left, make a signal.
signals(Bytes, Tty) ->
    {Actions, _} = fed([Bytes], Tty),
    lists:keymember(signal, 1, Actions).

%% Each chunk as an owner feeds it, again on what a signal key left untaken.
fed(Chunks, Tty0) ->
    {Actions, Tty} = lists:foldl(fun fed_chunk/2, {[], Tty0}, Chunks),
    {joined(Actions), Tty}.

fed_chunk(<<>>, Acc) ->
    Acc;
fed_chunk(Chunk, {Actions, Tty}) ->
    {More, Rest, Tty1} = erx_tty:input(Chunk, Tty),
    fed_chunk(Rest, {Actions ++ More, Tty1}).

joined([{echo, A}, {echo, B} | Rest]) ->
    joined([{echo, <<A/binary, B/binary>>} | Rest]);
joined([Action | Rest]) -> [Action | joined(Rest)];
joined([]) -> [].

check_actions(Actions) ->
    lists:foreach(fun(Action) -> check(action(Action), unknown_action, Action) end, Actions).

action({echo, Bytes}) -> is_binary(Bytes) andalso Bytes =/= <<>>;
action({signal, S}) -> lists:member(S, [sigint, sigquit, sigtstp]);
action({ready, _}) -> true;
action({timer_start, {_, N}, Ms}) -> is_integer(N) andalso Ms >= 100 andalso Ms =< 25500;
action({timer_cancel, {_, N}}) -> is_integer(N);
action(A) -> lists:member(A, [info, flush_output, stop_output, start_output]).

%%% Termios, valid and broken

random_termios() ->
    #{iflag => subset(?IFLAGS), oflag => subset(?OFLAGS), cflag => subset(?CFLAGS),
      lflag => subset(?LFLAGS), csize => 4 + rand:uniform(4),
      cc => maps:from_list([{Name, random_char(Name)} || Name <- ?CHARS]),
      ispeed => pick([0, 9600, 115200, 16#ffffffff]), ospeed => pick([0, 9600, 38400])}.

random_char(Name) when Name =:= vmin; Name =:= vtime -> pick([0, 0, 1, 2, 5, 255]);
random_char(_) -> pick([255, 3, 4, 10, 13, 17, 19, 20, 21, 23, 127, rand:uniform(256) - 1]).

%% What set/2 keeps: sorted flags, and an input speed of 0 as the output speed.
normal(#{ispeed := In, ospeed := Out} = Termios) ->
    Sorted = maps:map(fun(_, V) when is_list(V) -> lists:usort(V); (_, V) -> V end, Termios),
    Sorted#{ispeed := case In of 0 -> Out; _ -> In end}.

%% A termios broken one way.
broken(Termios) ->
    #{cc := Chars} = Termios,
    Field = pick([iflag, oflag, cflag, lflag]),
    Flags = maps:get(Field, Termios),
    case rand:uniform(11) of
        1 -> Termios#{Field := [bogus | Flags]};
        2 -> Termios#{Field := [pick(foreign(Field)) | Flags]};
        3 -> Termios#{Field := Flags ++ improper};
        4 -> Termios#{cc := Chars#{pick(?CHARS) := pick([256, -1, x, 1.5])}};
        5 -> Termios#{cc := maps:remove(pick(?CHARS), Chars)};
        6 -> Termios#{cc := Chars#{vbogus => 1}};
        7 -> Termios#{csize := pick([4, 9, eight])};
        8 -> Termios#{pick([ispeed, ospeed]) := pick([-1, 16#100000000, 9600.0])};
        9 -> maps:remove(pick([iflag, cc, csize, ospeed]), Termios);
        10 -> Termios#{extra => []};
        11 -> pick([[], <<>>, {termios}, Chars])
    end.

foreign(iflag) -> ?OFLAGS ++ ?LFLAGS;
foreign(oflag) -> ?IFLAGS ++ ?CFLAGS;
foreign(cflag) -> ?LFLAGS ++ ?OFLAGS;
foreign(lflag) -> ?IFLAGS ++ ?CFLAGS.

%%% Struct termios, valid and broken

random_struct() ->
    Word = fun() -> pick([0, 16#ffffffff, rand:uniform(1 bsl 32) - 1]) end,
    #{iflag => Word(), oflag => Word(), cflag => Word(), lflag => Word(),
      cc => [rand:uniform(256) - 1 || _ <- lists:seq(1, 20)],
      ispeed => pick([0, 9600, 16#ffffffff]), ospeed => pick([0, 38400])}.

%% A struct broken one way.
broken_struct(#{cc := Cc} = Struct) ->
    case rand:uniform(8) of
        1 -> Struct#{pick([iflag, oflag, cflag, lflag, ispeed, ospeed]) := pick([-1, 1 bsl 32, 1.0, x])};
        2 -> Struct#{cc := pick([tl(Cc), [0 | Cc], []])};
        3 -> Struct#{cc := [pick([256, -1, x]) | tl(Cc)]};
        4 -> Struct#{cc := lists:droplast(Cc) ++ 0};
        5 -> maps:remove(pick([iflag, cc, ospeed]), Struct);
        6 -> Struct#{extra => 0};
        7 -> Struct#{cc := list_to_binary(Cc)};
        8 -> pick([[], <<>>, {termios}, Cc])
    end.

%% Every bit of each word of Encoded is set in Struct, and every byte of
%% c_cc is Struct's or _POSIX_VDISABLE.
within(Encoded, Struct) ->
    Words = [W || W <- [iflag, oflag, cflag, lflag, ispeed, ospeed],
                  maps:get(W, Encoded) band bnot maps:get(W, Struct) =/= 0],
    Bytes = [{E, S} || {E, S} <- lists:zip(maps:get(cc, Encoded), maps:get(cc, Struct)),
                       E =/= S, E =/= 16#ff],
    Words =:= [] andalso Bytes =:= [].

%%% Helpers

%% Random bytes, or a long line and a run of the termios's VREPRINT, whose
%% echo with ECHO, ICANON and IEXTEN passes one call's bound many times.
random_input(#{cc := #{vreprint := Reprint}}) ->
    case rand:uniform(8) of
        1 -> <<(binary:copy(<<$a>>, 1000))/binary,
               (binary:copy(<<Reprint>>, 40))/binary>>;
        _ -> random_bytes()
    end.

random_bytes() ->
    Size = pick([1, 2, 8, 64, 1000, 5000]),
    Specials = [3, 4, 10, 13, 17, 19, 20, 21, 23, 127, 255, $\t, $\s, $a, 16#c3, 16#a9],
    << <<(case rand:uniform(3) of
              1 -> rand:uniform(256) - 1;
              _ -> pick(Specials)
          end)>> || _ <- lists:seq(1, rand:uniform(Size)) >>.

subset(Table) -> [F || F <- Table, rand:uniform(2) =:= 1].

pick(List) -> lists:nth(rand:uniform(length(List)), List).

has(Flag, #{iflag := I, oflag := O, cflag := C, lflag := L}) ->
    lists:member(Flag, I ++ O ++ C ++ L).

check(true, _, _) -> ok;
check(false, Property, Detail) -> fail(Property, Detail).

fail(Property, Detail) -> error({fuzz_failure, Property, Detail}).
