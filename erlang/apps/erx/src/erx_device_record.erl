%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The device records a domain's ERTS finds among its boot arguments (docs/design-fiasco.md,
%% "Device records"), one per device the domain drives, in one of two forms, each with its
%% own word so neither is told from the other by counting:
%%
%% - `-erx_record given ROLE PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK COHERENT MAC
%%   INDEX`,
%%   a given device: the handles of the window, line and memory objects the domain library
%%   installed when it created the domain, or the root made for itself at boot for a device
%%   the system domain holds, the transport's offset and size in the window object, the
%%   memory's bytes, 0 for a device that does no DMA, the firmware tree's coherence mark
%%   and hardware address, and INDEX, the device's row in the manifest's device table, by
%%   which the PCIe domain matches a host bridge's record to its erx_pcie_bridge index;
%% - `-erx_record device ROLE PERIPHERAL PATH BASE SIZE LINE MARK CLOCK INDEX`, the system domain's physical record
%%   of its host link's UART or its line's, which do no DMA, built by
%%   liberx/backend/core/boot_manifest.c from the system manifest; INDEX is the device's
%%   row in the manifest's device table, which a line grant's uart names.
%%
%% A domain that holds a framebuffer finds a third form, `-erx_record framebuffer WINDOW_H OFFSET
%% SIZE WIDTH HEIGHT STRIDE FORMAT`, read by framebuffers/0 (docs/design-device-tree.md,
%% "Facts into records"): the handle of the object over the framebuffer's pages, the
%% framebuffer's offset in them and its bytes, its geometry and its format's name, all from
%% the firmware's device tree. The root writes it only for a framebuffer the tree placed in
%% its row's window, so a domain whose firmware set none up finds `{ok, []}`. The storage
%% domain that serves `system` finds a fourth, `-erx_record system_image`, read by
%% system_image/0: the layout and root hash of the booted slot's system partition, and
%% whether the domain holds the manifest's record_volume window too (record_volume/1).
%%
%% In both device forms PATH is the device's device-tree path from its manifest row, its name
%% (docs/design-system.md, "Devices"): a node path of the characters a device tree allows in
%% names, `/` first, of at most ERX_DEVICE_PATH_MAX bytes, as the writer
%% (erx_boot_device_path_valid) has it; any other word refuses the record, so a name a driver
%% shows holds no control or escape, and it reaches a display only through that sink's
%% escaping function.
%%
%% In both device forms CLOCK is the device's clock in hertz from its manifest row, 0 for a device
%% whose driver reads none, so a driver reads its clock the same way whichever form it gets.
%% MARK is `shared` when another device of the unit names the line and `direct` otherwise,
%% as the record's writer found it (docs/design-shared-devices.md, "Lines inside a domain"),
%% and a shared line reaches erx_device:open/1 as `{shared, Line}`; any other word refuses
%% the record, so no line is read as one mark or the other by default.
%%
%% A driver asks for the records of its role and its peripheral and opens each with
%% erx_device:open/1. No record is a normal state, a machine without a disk, and is
%% `{ok, []}`: the driver then has nothing to drive. Whether a disk is behind a transport is
%% the driver's first reads of it to say, not the record's.

-module(erx_device_record).

-include("generated/erx_abi.hrl").

-export([records/0, find/2, find/3, framebuffers/0, framebuffers/1, system_image/0, system_image/1,
         record_volume/1]).
-export_type([spec/0, framebuffer/0, format/0, system_image/0]).

%% What erx_device:open/1 takes: a given device's objects, or a physical device's window and
%% line, each with its clock for its driver.
-type spec() :: #{peripheral := atom(), path := binary(),
                  window := {object, non_neg_integer(), non_neg_integer(), non_neg_integer()},
                  lines := [{object, non_neg_integer()} | {shared, {object, non_neg_integer()}}],
                  memory => {object, non_neg_integer(), pos_integer()}, clock := non_neg_integer(),
                  coherent := boolean(), mac => 1..16#ffffffffffff,
                  index := non_neg_integer()}
              | #{peripheral := atom(), path := binary(), window := {physical, non_neg_integer(), non_neg_integer()},
                  lines := [non_neg_integer() | {shared, non_neg_integer()}], clock := non_neg_integer(),
                  index := non_neg_integer()}
              | #{peripheral := atom(), place := {non_neg_integer(), byte(), 0..31, 0..7},
                  window := {object, non_neg_integer(), non_neg_integer(), pos_integer()},
                  lines := [{object, non_neg_integer()} | {shared, {object, non_neg_integer()}}],
                  memory => {object, non_neg_integer(), pos_integer()}, coherent := boolean(),
                  msix => #{address := non_neg_integer(), data := non_neg_integer(), bar := 0..5,
                            offset := non_neg_integer(), entries := 0..2048}}.

%% A framebuffer record as its display driver takes it: the window object and the
%% framebuffer's offset and bytes in it, as a given record's window, and its geometry.
-type framebuffer() :: #{window := {object, non_neg_integer(), non_neg_integer(), pos_integer()},
                         width := pos_integer(), height := pos_integer(), stride := pos_integer(),
                         format := format()}.

%% The system_image record's layout, or why it was refused.
-type system_image() :: {ok, erx_verity_tree:layout()} | {error, {bad_device_record, string()}}.

%% The simple-framebuffer binding's formats, the device-tree reader's table.
-type format() :: a1r5g5b5 | a2r10g10b10 | a8b8g8r8 | a8r8g8b8 | r5g6b5 | r5g5b5a1 | r8g8b8 | x1r5g5b5
                | x2r10g10b10 | x8r8g8b8 | x8b8g8r8.

%% The records of Role and Peripheral among the boot records.
-spec find(atom(), atom()) -> {ok, [spec()]} | {error, {bad_device_record, string()}}.
find(Role, Peripheral) ->
    find(Role, Peripheral, records()).

%% The framebuffer records among the boot records.
-spec framebuffers() -> {ok, [framebuffer()]} | {error, {bad_device_record, string()}}.
framebuffers() ->
    framebuffers(records()).

%% Pure, as find/3 is. A record whose words do not parse, or whose geometry the reader of
%% the tree would not have passed (a zero dimension, a stride short of a row, rows past
%% its bytes), refuses them all, since the writer and this reader then disagree.
-spec framebuffers([[string()]]) -> {ok, [framebuffer()]} | {error, {bad_device_record, string()}}.
framebuffers(Arguments) ->
    collect(fun framebuffer/1, [Words || ["framebuffer" | Words] <- Arguments], []).

%% The system_image record among the boot records.
-spec system_image() -> system_image().
system_image() ->
    system_image(records()).

%% Pure, as find/3 is. The record is the booted slot's system partition as its storage
%% domain opens it in erx_verity (docs/design-fiasco.md, "The booted slot"), a layout
%% whose image starts at the partition's byte 0. The domain library writes it,
%% `-erx_record system_image LEN TREE_OFF TREE_LEN SALT ROOT [record_volume]`, only to
%% the storage domain that serves `system`, so exactly one record is taken, of five
%% words or of six whose sixth is `record_volume` (record_volume/1): LEN, TREE_OFF and
%% TREE_LEN decimals within 64 bits, SALT 2 to 64 lowercase hex digits, an even count,
%% and ROOT exactly 64. Any other shape, a second record and none are refused with the
%% reason, and the caller then opens no image.
-spec system_image([[string()]]) -> system_image().
system_image(Arguments) ->
    case image_record(Arguments) of
        {ok, Layout, _RecordVolume} -> {ok, Layout};
        Refused -> Refused
    end.

%% Pure. True when Arguments hold the one system_image record system_image/1 takes and its
%% sixth word is the name abi/manifest.txt gives the record_volume window role, which the
%% domain library adds for the holder of the manifest's record_volume window, the domain
%% the record goes to; false for any other record and for one system_image/1 refuses.
-spec record_volume([[string()]]) -> boolean().
record_volume(Arguments) ->
    case image_record(Arguments) of
        {ok, _Layout, RecordVolume} -> RecordVolume;
        {error, _} -> false
    end.

%% The one system_image record of Arguments as {ok, Layout, NamesRecordVolume}, or the
%% refusal system_image/1 answers.
image_record(Arguments) when not is_list(Arguments) ->
    bad("the boot records are not a list");
image_record(Arguments) ->
    case [Words || ["system_image" | Words] <- Arguments] of
        [[Length, TreeOffset, TreeLength, Salt, Root | Windows]] when Windows =:= []; Windows =:= ["record_volume"] ->
            case {numbers([Length, TreeOffset, TreeLength]), hex(Salt, 1, ?ERX_VERITY_SALT_SIZE), hex(Root, ?ERX_VERITY_HASH_SIZE, ?ERX_VERITY_HASH_SIZE)} of
                {{ok, [L, O, T]}, {ok, S}, {ok, R}} ->
                    {ok, #{image_offset => 0, image_length => L, tree_offset => O, tree_length => T, salt => S,
                           root_hash => R}, Windows =/= []};
                {error, _, _} ->
                    bad("a system_image record's length, tree offset or tree length is not a decimal number "
                        "of 64 bits");
                {_, error, _} ->
                    bad("a system_image record's salt is not 1 to " ++ integer_to_list(?ERX_VERITY_SALT_SIZE)
                        ++ " bytes in lowercase hex");
                {_, _, error} ->
                    bad("a system_image record's root hash is not " ++ integer_to_list(?ERX_VERITY_HASH_SIZE)
                        ++ " bytes in lowercase hex")
            end;
        [_] ->
            bad("a system_image record is not five words, a length, a tree offset and length, a salt and a root "
                "hash, then at most record_volume");
        [] ->
            bad("no system_image record");
        [_, _ | _] ->
            bad("more than one system_image record")
    end.

%% Every boot record of this runtime's boot page, each the word list after one
%% `-erx_record` flag, as init:get_argument/1 returns them, or [] when the page has none.
%% The flag's one source is abi/erx_abi.txt's boot_record_flag, and this is its one
%% reader: every record's parser takes its words from here. The flag names no
%% application, so the application controller reads none of the words as environment.
-spec records() -> [[string()]].
records() ->
    case init:get_argument(binary_to_atom(?ERX_BOOT_RECORD_FLAG_BYTES)) of
        {ok, Found} -> Found;
        error -> []
    end.

%% Pure, for its tests and fuzz target. A record of another role or peripheral is left
%% alone. A plain word of the kernel command line joins the flag before it, so a record
%% may run on past its numbers; the words after them are not the record's. A record of
%% Role and Peripheral whose numbers do not parse refuses them all, since a malformed
%% record says the writer and this reader disagree.
-spec find(atom(), atom(), [[string()]]) ->
    {ok, [spec()]} | {error, {bad_device_record, string()}}.
find(Role, Peripheral, Arguments) ->
    RoleWord = atom_to_list(Role),
    PeripheralWord = atom_to_list(Peripheral),
    Records = [{Form, Words} || [Form, R, P | Words] <- Arguments,
                                Form =:= "device" orelse Form =:= "given" orelse Form =:= "function",
                                R =:= RoleWord, P =:= PeripheralWord],
    collect(fun(Record) -> spec(Peripheral, Record) end, Records, []).

collect(_Parse, [], Specs) ->
    {ok, lists:reverse(Specs)};
collect(Parse, [Record | Rest], Specs) ->
    case Parse(Record) of
        {ok, Spec} -> collect(Parse, Rest, [Spec | Specs]);
        {error, _} = Error -> Error
    end.

framebuffer([Window, Offset, Size, Width, Height, Stride, Format | _]) ->
    case {numbers([Window, Offset, Size]), [number(Word, 32) || Word <- [Width, Height, Stride]], format(Format)} of
        {{ok, [W, O, S]}, [{ok, X}, {ok, Y}, {ok, R}], {ok, F, Bits}}
          when S > 0, X > 0, Y > 0, R > 0, R * 8 >= X * Bits, R * Y =< S ->
            {ok, #{window => {object, W, O, S}, width => X, height => Y, stride => R, format => F}};
        {{ok, _}, [{ok, _}, {ok, _}, {ok, _}], {ok, _, _}} ->
            bad("a framebuffer record's geometry does not fit its bytes");
        {{ok, _}, [{ok, _}, {ok, _}, {ok, _}], error} ->
            bad("a framebuffer record's format is not one of the binding's");
        _ ->
            bad("a framebuffer record's handle, offset, size or geometry is not a decimal number "
                "of its field's width")
    end;
framebuffer(_Words) ->
    bad("a framebuffer record has fewer than six numbers and a format").

%% A format's name and its bits per pixel, as kernel/core/dt.c's table has them.
format("a1r5g5b5") -> {ok, a1r5g5b5, 16};
format("a2r10g10b10") -> {ok, a2r10g10b10, 32};
format("a8b8g8r8") -> {ok, a8b8g8r8, 32};
format("a8r8g8b8") -> {ok, a8r8g8b8, 32};
format("r5g6b5") -> {ok, r5g6b5, 16};
format("r5g5b5a1") -> {ok, r5g5b5a1, 16};
format("r8g8b8") -> {ok, r8g8b8, 24};
format("x1r5g5b5") -> {ok, x1r5g5b5, 16};
format("x2r10g10b10") -> {ok, x2r10g10b10, 32};
format("x8r8g8b8") -> {ok, x8r8g8b8, 32};
format("x8b8g8r8") -> {ok, x8b8g8r8, 32};
format(_Word) -> error.

%% COHERENT is the firmware tree's coherence mark, 0 or 1, and MAC its hardware address,
%% 48 bits, 0 for none (docs/design-device-tree.md, "Facts into records"); INDEX the
%% device's row in the manifest's device table, as a device record's.
spec(Peripheral, {"given", [Path, Window, Offset, Size, Line, Mark, Memory, MemorySize, Clock, Coherent, Mac, Index
                            | _]}) ->
    case {numbers([Window, Offset, Size, Line, Memory, MemorySize]), {number(Clock, 32), number(Index, 32)},
          mark(Mark), coherent(Coherent), number(Mac, 48), path(Path)} of
        {{ok, [_, _, _, ?ERX_CAP_NULL, _, _]}, {{ok, _}, {ok, _}}, {ok, shared}, {ok, _}, {ok, _}, {ok, _}} ->
            bad("a given device record marks no line shared");
        {{ok, [W, O, S, L, M, MS]}, {{ok, C}, {ok, I}}, {ok, Sharing}, {ok, Co}, {ok, A}, {ok, P}} ->
            Spec = #{peripheral => Peripheral, path => P, window => {object, W, O, S},
                     lines => given_lines(Sharing, L), clock => C, coherent => Co, index => I},
            {ok, with_mac(with_memory(Spec, M, MS), A)};
        {{ok, _}, {{ok, _}, {ok, _}}, {ok, _}, {ok, _}, {ok, _}, error} ->
            bad("a given device record's path is not a node path of at most "
                ++ integer_to_list(?ERX_DEVICE_PATH_MAX) ++ " bytes");
        {{ok, _}, {{ok, _}, {ok, _}}, error, _, _, _} ->
            bad("a given device record's line mark is neither direct nor shared");
        {{ok, _}, {{ok, _}, {ok, _}}, {ok, _}, error, _, _} ->
            bad("a given device record's coherence is neither 0 nor 1");
        _ ->
            bad("a given device record's handle, offset, size, clock, address or index is not a decimal "
                "number of its field's width")
    end;
spec(_Peripheral, {"given", _}) ->
    bad("a given device record has fewer than a path, ten numbers and a line mark");
spec(Peripheral, {"device", [Path, Base, Size, Line, Mark, Clock, Index | _]}) ->
    case {number(Base, 64), number(Size, 64), number(Line, 32), {number(Clock, 32), number(Index, 32)}, mark(Mark), path(Path)} of
        {{ok, B}, {ok, S}, {ok, L}, {{ok, C}, {ok, I}}, {ok, Sharing}, {ok, P}} ->
            {ok, #{peripheral => Peripheral, path => P, window => {physical, B, S}, lines => [marked(Sharing, L)],
                   clock => C, index => I}};
        {{ok, _}, {ok, _}, {ok, _}, {{ok, _}, {ok, _}}, {ok, _}, error} ->
            bad("a device record's path is not a node path of at most "
                ++ integer_to_list(?ERX_DEVICE_PATH_MAX) ++ " bytes");
        {{ok, _}, {ok, _}, {ok, _}, {{ok, _}, {ok, _}}, error, _} ->
            bad("a device record's line mark is neither direct nor shared");
        _ ->
            bad("a device record's base, size, line, clock or index is not a decimal number of its field's width")
    end;
spec(_Peripheral, {"device", _}) ->
    bad("a device record has fewer than a path, five numbers and a line mark");
%% A given PCIe function's record (docs/design-pcie.md, "The catalogue and gives"), written by
%% erx_boot_function_words: its place, its line, its memory, its coherence, its route with an
%% MSI-X route's message and table, then each of the six BARs' WINDOW_H OFFSET SIZE_LOG2, a BAR
%% not placed with the null handle. Its window is its first placed BAR's, BAR 0 for every
%% function erXos drives; `place` is what the device service's `pci` facet names it by, and
%% `msix` the message and table the NIF writes after the driver's reset.
spec(Peripheral, {"function", [Bridge, Bus, Device, Function, Line, Mark, Memory, MemorySize, Coherent, Route,
                               Address, Data, TableBar, TableOffset, TableSize | Bars]}) when length(Bars) >= 18 ->
    case {numbers([Bridge, Bus, Device, Function, Line, Memory, MemorySize, Address, Data, TableBar, TableOffset,
                   TableSize]), mark(Mark), coherent(Coherent), route(Route), function_window(lists:sublist(Bars, 18))} of
        {{ok, [B, Bu, D, F, L, M, MS, A, Da, TB, TO, TS]}, {ok, Sharing}, {ok, Co}, {ok, R}, {ok, Window}}
          when B =< 16#ffffffff, Bu =< 255, D =< 31, F =< 7, Da =< 16#ffffffff, TB =< 5, TO =< 16#ffffffff,
               TS =< 2048 ->
            Spec = #{peripheral => Peripheral, place => {B, Bu, D, F}, window => Window,
                     lines => given_lines(Sharing, L), coherent => Co},
            Table = #{address => A, data => Da, bar => TB, offset => TO, entries => TS},
            {ok, with_msix(with_memory(Spec, M, MS), R, Table)};
        {{ok, _}, {ok, _}, {ok, _}, {ok, _}, error} ->
            bad("a function record places no memory BAR");
        {{ok, _}, {ok, _}, {ok, _}, error, _} ->
            bad("a function record's route is not none, msi, msix or intx");
        {{ok, _}, error, _, _, _} ->
            bad("a function record's line mark is neither direct nor shared");
        {{ok, _}, {ok, _}, error, _, _} ->
            bad("a function record's coherence is neither 0 nor 1");
        _ ->
            bad("a function record's place, handle, size, message or table is not a decimal number "
                "of its field's width")
    end;
spec(_Peripheral, {"function", _}) ->
    bad("a function record has fewer than its place, a line mark, a route and six BARs").

route("none") -> {ok, none};
route("msi") -> {ok, msi};
route("msix") -> {ok, msix};
route("intx") -> {ok, intx};
route(_Word) -> error.

%% The first placed BAR's window over its hardware size, 2 to its SIZE_LOG2, from the six
%% BARs' words, or error when a word is not a number or the record places no BAR. Every word
%% is read before a window is chosen.
function_window(Words) ->
    case numbers(Words) of
        {ok, Numbers} ->
            case [{object, W, O, 1 bsl S} || {W, O, S} <- triples(Numbers), W =/= ?ERX_CAP_NULL, S >= 4, S =< 63] of
                [Window | _] -> {ok, Window};
                [] -> error
            end;
        error ->
            error
    end.

triples([W, O, S | Rest]) -> [{W, O, S} | triples(Rest)];
triples([]) -> [].

with_msix(Spec, msix, Table) -> Spec#{msix => Table};
with_msix(Spec, _Route, _Table) -> Spec.

%% A device record's PATH as erx_boot_device_path_valid admits it: `/` and the characters a
%% device tree allows in names, at most ERX_DEVICE_PATH_MAX bytes, so with its NUL it fits
%% the word the writer reserves. The length is checked before the characters, so no word
%% longer than the bound is copied.
path([$/ | _] = Word) when length(Word) =< ?ERX_DEVICE_PATH_MAX ->
    case lists:all(fun node_char/1, Word) of
        true -> {ok, list_to_binary(Word)};
        false -> error
    end;
path(_Word) ->
    error.

node_char(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 -> true;
node_char(C) -> lists:member(C, ",._+-@/").

coherent("0") -> {ok, false};
coherent("1") -> {ok, true};
coherent(_) -> error.

with_mac(Spec, 0) -> Spec;
with_mac(Spec, Address) -> Spec#{mac => Address}.

%% The line's mark word, and the line as erx_device:open/1 takes it.
mark("direct") -> {ok, direct};
mark("shared") -> {ok, shared};
mark(_Word) -> error.

marked(direct, Line) -> Line;
marked(shared, Line) -> {shared, Line}.

%% A device whose node raises no line, a host bridge's such as QEMU virt's ECAM, has no line
%% object, and its record names the null handle, marked direct (spec/2 refuses it shared).
given_lines(_Sharing, ?ERX_CAP_NULL) -> [];
given_lines(Sharing, Line) -> [marked(Sharing, {object, Line})].

%% A device that does no DMA has no memory object, and its record says 0 bytes.
with_memory(Spec, _Memory, 0) -> Spec;
with_memory(Spec, Memory, Bytes) -> Spec#{memory => {object, Memory, Bytes}}.

bad(Text) ->
    {error, {bad_device_record, Text}}.

numbers(Words) ->
    Parsed = [number(Word, 64) || Word <- Words],
    case lists:all(fun(Result) -> Result =/= error end, Parsed) of
        true -> {ok, [Value || {ok, Value} <- Parsed]};
        false -> error
    end.

%% Lowercase hex digits spelling MinBytes to MaxBytes bytes, two digits a byte, as those
%% bytes. The length is checked before the digits, so no word longer than the bound is decoded.
hex(Word, MinBytes, MaxBytes) ->
    case length(Word) of
        Digits when Digits >= 2 * MinBytes, Digits =< 2 * MaxBytes, Digits rem 2 =:= 0 ->
            case lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, Word) of
                true -> {ok, binary:decode_hex(list_to_binary(Word))};
                false -> error
            end;
        _ ->
            error
    end.

%% Digits only, at most as many as the field's largest value has, so no word builds a large
%% integer before the range check.
number(Word, Bits) ->
    Max = (1 bsl Bits) - 1,
    case Word =/= [] andalso length(Word) =< length(integer_to_list(Max))
        andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Word) of
        true ->
            case list_to_integer(Word) of
                Value when Value =< Max -> {ok, Value};
                _ -> error
            end;
        false ->
            error
    end.
