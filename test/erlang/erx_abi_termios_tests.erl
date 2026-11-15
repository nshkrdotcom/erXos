%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The termios codec generated from abi/termios.txt, erx_abi_termios
%% (docs/design-live.md, "The tty"), against FreeBSD 15.1's numbers written
%% out here from sys/sys/_termios.h and sys/sys/ttydefaults.h, independently
%% of the table: FreeBSD's default struct termios is erx_tty's new termios
%% both ways, a bit or byte the table does not name is dropped, and a struct
%% that is not four words, NCCS bytes and two speeds is refused.

-module(erx_abi_termios_tests).
-include_lib("eunit/include/eunit.hrl").

%% FreeBSD's TTYDEF_IFLAG, _OFLAG, _CFLAG (CS8) and _LFLAG, TTYDEF_SPEED and
%% ttydefchars, c_cc[19] being the spare _POSIX_VDISABLE.
freebsd_default() ->
    #{iflag => 16#6b02, oflag => 16#3, cflag => 16#4b00, lflag => 16#5cb,
      cc => [4, 255, 255, 127, 23, 21, 18, 8, 3, 28, 26, 25, 17, 19, 22, 15, 1, 0, 20, 255],
      ispeed => 9600, ospeed => 9600}.

default_decodes_to_erx_tty_default_test() ->
    ?assertEqual({ok, erx_tty:termios(erx_tty:new())}, erx_abi_termios:decode(freebsd_default())).

default_encodes_to_freebsd_default_test() ->
    ?assertEqual(freebsd_default(), erx_abi_termios:encode(erx_tty:termios(erx_tty:new()))).

%% Every bit set: the words keep only the bits FreeBSD supports and erx_tty
%% keeps, CSIZE reads as CS8, and the spare byte comes back disabled.
unnamed_bits_dropped_test() ->
    All = #{iflag => 16#ffffffff, oflag => 16#ffffffff, cflag => 16#ffffffff,
            lflag => 16#ffffffff, cc => lists:duplicate(20, 7), ispeed => 0, ospeed => 0},
    {ok, Termios} = erx_abi_termios:decode(All),
    ?assertEqual(8, maps:get(csize, Termios)),
    ?assertEqual(erx_abi_termios:flags(lflag), maps:get(lflag, Termios)),
    #{iflag := I, oflag := O, cflag := C, lflag := L, cc := Cc} = erx_abi_termios:encode(Termios),
    %% IGNBRK..IXANY, IMAXBEL, IUTF8; OPOST..ONLRET; CSIZE..CLOCAL;
    %% ECHOKE..ECHONL, ECHOCTL..IEXTEN, TOSTOP, NOKERNINFO, NOFLSH.
    ?assertEqual({16#6fff, 16#7f, 16#ff00, 16#824007df}, {I, O, C, L}),
    ?assertEqual(lists:duplicate(19, 7) ++ [255], Cc).

%% Only bits the table does not name: ECHOPRT, EXTPROC, FLUSHO and PENDIN,
%% CIGNORE and the modem flow-control flags, and unassigned bits.
only_unnamed_bits_test() ->
    Struct = (freebsd_default())#{iflag := 16#1000, oflag := 16#80, cflag := 16#3f0001,
                                  lflag := 16#20800820},
    {ok, Termios} = erx_abi_termios:decode(Struct),
    ?assertMatch(#{iflag := [], oflag := [], cflag := [], lflag := [], csize := 5}, Termios),
    ?assertMatch(#{iflag := 0, oflag := 0, cflag := 0, lflag := 0},
                 erx_abi_termios:encode(Termios)).

csize_reads_cs5_to_cs8_test() ->
    Sizes = [begin
                 {ok, #{csize := Size}} = erx_abi_termios:decode((freebsd_default())#{cflag := Bits}),
                 Size
             end || Bits <- [16#0, 16#100, 16#200, 16#300]],
    ?assertEqual([5, 6, 7, 8], Sizes).

refused_test_() ->
    Default = freebsd_default(),
    Cc = maps:get(cc, Default),
    Broken = [Default#{iflag := -1}, Default#{lflag := 1 bsl 32}, Default#{ospeed := 9600.0},
              Default#{cflag := x}, Default#{cc := tl(Cc)}, Default#{cc := [0 | Cc]},
              Default#{cc := [256 | tl(Cc)]}, Default#{cc := lists:droplast(Cc) ++ 0},
              Default#{cc := list_to_binary(Cc)}, maps:remove(ispeed, Default),
              Default#{extra => 0}, [], Cc],
    [?_assertEqual({error, einval}, erx_abi_termios:decode(Struct)) || Struct <- Broken].

tables_test() ->
    ?assertEqual(lists:sort(maps:keys(maps:get(cc, erx_tty:termios(erx_tty:new())))),
                 erx_abi_termios:chars()),
    ?assertEqual([14, 7, 6, 13], [length(erx_abi_termios:flags(W)) || W <- [iflag, oflag, cflag, lflag]]).
