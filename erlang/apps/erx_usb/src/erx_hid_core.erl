%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hid_core).
-moduledoc """
The HID function's fold (docs/design-usb.md, "From reports to records"):
the reports a HID interface sends, read against the layout
`erx_hid_desc` parsed, become the input records the display's input
router takes, `erx_input:record()`.

roles/1 says what a layout can report, from its usages and not from the
interface's protocol: `keys`, Keyboard/Keypad page fields; `pointer`, a
Generic Desktop X and Y in one report, relative, or absolute over a range
whose maximum is above its minimum; `buttons`, Button page usages 1 to 3;
`wheel`, a Generic Desktop Wheel. A layout with none is not driven.

step/3 folds one report. The state keeps, for each report id the layout
has, the keys and buttons that id's last report held and its last
absolute position, and the held set is their union, so a report of id 2
never releases a key id 1 holds, as FreeBSD's `hkbd` clears and sets only
the keys of the received id (`hkbd.c`, lines 706-745). One report gives,
in order: a relative move, an absolute position that changed, wheel
steps, then the keys and buttons released and then those pressed, each in
ascending code order, so a click lands where the report put the pointer.
A report whose keyboard array values all hold ErrorRollOver is the
phantom state of HID 1.11, Appendix C, and changes nothing.

A field's values are read little-endian from its bit offset, signed where
its logical minimum is negative (HID 1.11, section 5.8). A variable field's
value i has the field's usage i, or its last; an array field's value v
names usage `v - min`, and usage 0 of a page is no key. Keys and buttons
map to evdev codes through `abi/formats/hid.txt`'s translations; a key
usage the table maps to no code is dropped and counted.

Every report is untrusted input. A report of an id the layout lacks, or
shorter than its id's fields, is dropped and counted; the layout puts
every field inside its report's length, so no read passes the end. Every
record is held to `abi/formats/input.txt`'s bounds, and the state's size
is fixed by the layout however long the device reports. None of it
raises on any report, which `test/erlang/erx_hid_core_fuzz.erl` checks.
""".

-export([roles/1, transfer_length/1, new/1, step/3, counts/1]).

-export_type([role/0, state/0, counts/0]).

-include("generated/erx_abi.hrl").

-type role() :: keys | pointer | buttons | wheel.

-type counts() :: #{unmapped := non_neg_integer(), short := non_neg_integer(),
                    unknown_id := non_neg_integer()}.

%% What one id's last report left: the codes held, ascending, and the position.
-type entry() :: #{held := ordsets:ordset(code()), position := none | {axis(), axis()}}.

-opaque state() :: #{entries := #{erx_hid_desc:report_id() => entry()}, counts := counts()}.

-type axis() :: 0..?ERX_INPUT_AXIS_MAX.

%% An evdev key or button code, as the translations of abi/formats/hid.txt give it.
-type code() :: non_neg_integer().

-define(PAGE(Usage), ((Usage) bsr 16)).
-define(ID(Usage), ((Usage) band 16#ffff)).
-define(DESKTOP(Id), ((?ERX_HID_USAGE_PAGE_GENERIC_DESKTOP bsl 16) bor (Id))).

%% What a report says, gathered over its fields before any record is made.
-record(report, {held = [] :: [code()],
                 dx = 0 :: integer(),
                 dy = 0 :: integer(),
                 x = none :: none | axis(),
                 y = none :: none | axis(),
                 wheel = 0 :: integer(),
                 rollover = [] :: [boolean()],
                 unmapped = 0 :: non_neg_integer()}).

-doc "What a layout can report, each role once, in the order keys, pointer, buttons, wheel.".
-spec roles(erx_hid_desc:layout()) -> [role()].
roles(#{reports := Reports}) ->
    Found = [{Id, Role} || Id := #{fields := Fields} <- Reports, Field <- Fields, Role <- field_roles(Field)],
    Pointer = [pointer || {Id, x} <- Found, lists:member({Id, y}, Found)],
    [Role || Role <- [keys, pointer, buttons, wheel],
             lists:member(Role, Pointer) orelse lists:keymember(Role, 2, Found)].

%% A variable field's roles are those of the usages its values take; an array field's
%% those of every usage its values can name.
field_roles(Field = #{variable := true, count := Count}) ->
    lists:usort([role(variable_usage(Field, I), Field) || I <- lists:seq(0, Count - 1)]) -- [none];
field_roles(#{variable := false, usages := Usages}) ->
    lists:usort([array_role(Range) || Range <- Usages]) -- [none].

role(none, _) -> none;
role(Usage, _) when ?PAGE(Usage) =:= ?ERX_HID_USAGE_PAGE_KEYBOARD -> keys;
role(Usage, _) when ?PAGE(Usage) =:= ?ERX_HID_USAGE_PAGE_BUTTON ->
    case erx_abi_translations:hid_button_key(?ID(Usage)) of none -> none; _ -> buttons end;
role(?DESKTOP(?ERX_HID_DESKTOP_USAGE_WHEEL), _) -> wheel;
role(Usage, Field) when Usage =:= ?DESKTOP(?ERX_HID_DESKTOP_USAGE_X); Usage =:= ?DESKTOP(?ERX_HID_DESKTOP_USAGE_Y) ->
    case positional(Field) of
        true when Usage =:= ?DESKTOP(?ERX_HID_DESKTOP_USAGE_X) -> x;
        true -> y;
        false -> none
    end;
role(_, _) -> none.

%% An axis moves relatively, or absolutely over a range of more than one value.
positional(#{relative := true}) -> true;
positional(#{min := Min, max := Max}) -> Max > Min.

array_role({Lo, _Hi}) when ?PAGE(Lo) =:= ?ERX_HID_USAGE_PAGE_KEYBOARD -> keys;
array_role({Lo, Hi}) when ?PAGE(Lo) =:= ?ERX_HID_USAGE_PAGE_BUTTON ->
    Named = [U || U <- [1, 2, 3], erx_abi_translations:hid_button_key(U) =/= none,
                  ?ID(Lo) =< U, U =< ?ID(Hi), ?PAGE(Hi) =:= ?PAGE(Lo)],
    case Named of [] -> none; _ -> buttons end;
array_role(_) -> none.

-doc """
The length of each interrupt-IN transfer: the largest input report, with
its report-id byte when the layout numbers its reports, as FreeBSD sizes
its interrupt transfer (`usbhid.c`, lines 380-384).
""".
-spec transfer_length(erx_hid_desc:layout()) -> non_neg_integer().
transfer_length(#{largest := Largest, numbered := true}) -> Largest + 1;
transfer_length(#{largest := Largest, numbered := false}) -> Largest.

-doc "The state before the first report: nothing held and no position, for each report id.".
-spec new(erx_hid_desc:layout()) -> state().
new(#{reports := Reports}) ->
    #{entries => maps:map(fun(_, _) -> #{held => [], position => none} end, Reports),
      counts => #{unmapped => 0, short => 0, unknown_id => 0}}.

-doc "The records one report gives, and the state after it.".
-spec step(erx_hid_desc:layout(), binary(), state()) -> {[erx_input_codec:record()], state()}.
step(#{reports := Reports, numbered := Numbered}, Report, State) when is_binary(Report) ->
    case framed(Numbered, Report) of
        {Id, Body} when is_map_key(Id, Reports) ->
            #{fields := Fields, bytes := Bytes} = maps:get(Id, Reports),
            case byte_size(Body) >= Bytes of
                true -> fold(Id, lists:foldl(fun(Field, R) -> read(Field, Body, R) end, #report{}, Fields), State);
                false -> {[], count(short, 1, State)}
            end;
        {_Id, _Body} ->
            {[], count(unknown_id, 1, State)};
        empty ->
            {[], count(short, 1, State)}
    end.

-doc "How many reports and key usages were dropped, by reason.".
-spec counts(state()) -> counts().
counts(#{counts := Counts}) -> Counts.

framed(true, <<Id, Body/binary>>) -> {Id, Body};
framed(true, <<>>) -> empty;
framed(false, Body) -> {0, Body}.

count(Why, N, State = #{counts := Counts}) ->
    State#{counts := maps:update_with(Why, fun(Old) -> Old + N end, Counts)}.

%% The phantom report changes nothing at all; any other replaces its id's entry and
%% gives the moves, then the edges of the union of every id's held set.
fold(Id, R, State) ->
    case phantom(R) of
        true -> {[], State};
        false -> replaced(Id, R, State)
    end.

phantom(#report{rollover = Rollover}) -> Rollover =/= [] andalso lists:all(fun(Held) -> Held end, Rollover).

replaced(Id, R, State = #{entries := Entries}) ->
    Old = maps:get(Id, Entries),
    Position = position(R, maps:get(position, Old)),
    Next = Entries#{Id := #{held => lists:usort(R#report.held), position => Position}},
    Moves = moves(R, Position =/= maps:get(position, Old)) ++ wheel(R#report.wheel),
    Edges = edges(held(Entries), held(Next)),
    {Moves ++ Edges, count(unmapped, R#report.unmapped, State#{entries := Next})}.

held(Entries) -> lists:usort(lists:append([Held || _ := #{held := Held} <- Entries])).

%% An absolute position needs both axes in the report; without them the last stays.
position(#report{x = X, y = Y}, _) when X =/= none, Y =/= none -> {X, Y};
position(_, Last) -> Last.

moves(#report{dx = DX, dy = DY, x = X, y = Y}, Moved) ->
    [{pointer, rel, clamp(DX, ?ERX_INPUT_REL_MIN, ?ERX_INPUT_REL_MAX), clamp(DY, ?ERX_INPUT_REL_MIN, ?ERX_INPUT_REL_MAX)}
     || DX =/= 0 orelse DY =/= 0]
        ++ [{pointer, abs, X, Y} || Moved].

wheel(0) -> [];
wheel(Steps) -> [{wheel, clamp(Steps, ?ERX_INPUT_WHEEL_MIN, ?ERX_INPUT_WHEEL_MAX)}].

edges(Old, New) ->
    [{key, up, Code} || Code <- ordsets:subtract(Old, New)] ++ [{key, down, Code} || Code <- ordsets:subtract(New, Old)].

clamp(V, Min, Max) -> min(max(V, Min), Max).

%% Each value of a field adds what it says to the report.
read(Field = #{count := Count}, Body, R) ->
    lists:foldl(fun(I, Acc) -> value(Field, I, extract(Field, I, Body), Acc) end, R, lists:seq(0, Count - 1)).

extract(#{offset := Offset, size := Size, min := Min}, I, Body) ->
    Bit = Offset + I * Size,
    First = Bit div 8,
    Length = (Bit rem 8 + Size + 7) div 8,
    <<_:First/binary, Chunk:Length/binary, _/binary>> = Body,
    Raw = (binary:decode_unsigned(Chunk, little) bsr (Bit rem 8)) band ((1 bsl Size) - 1),
    case Min < 0 andalso Raw >= 1 bsl (Size - 1) of
        true -> Raw - (1 bsl Size);
        false -> Raw
    end.

value(Field = #{variable := true}, I, V, R) ->
    Usage = variable_usage(Field, I),
    variable(role(Usage, Field), Usage, V, Field, R);
value(Field = #{variable := false}, _I, V, R) ->
    array(array_usage(Field, V), R).

variable(keys, _, 0, _, R) -> R;
variable(keys, Usage, _, _, R) -> key(Usage, R);
variable(buttons, _, 0, _, R) -> R;
variable(buttons, Usage, _, _, R) -> R#report{held = [erx_abi_translations:hid_button_key(?ID(Usage)) | R#report.held]};
variable(x, _, V, #{relative := true}, R) -> R#report{dx = R#report.dx + V};
variable(y, _, V, #{relative := true}, R) -> R#report{dy = R#report.dy + V};
variable(x, _, V, Field, R) -> R#report{x = normalized(V, Field)};
variable(y, _, V, Field, R) -> R#report{y = normalized(V, Field)};
variable(wheel, _, V, _, R) -> R#report{wheel = R#report.wheel + V};
variable(none, _, _, _, R) -> R.

%% A keyboard array value takes part in the rollover test whatever it names; usage 0
%% of a page is no key.
array(none, R) -> R;
array(Usage, R) when ?PAGE(Usage) =:= ?ERX_HID_USAGE_PAGE_KEYBOARD ->
    Rollover = ?ID(Usage) =:= ?ERX_HID_KEY_ERROR_ROLL_OVER,
    Next = R#report{rollover = [Rollover | R#report.rollover]},
    case ?ID(Usage) of
        0 -> Next;
        _ when Rollover -> Next;
        _ -> key(Usage, Next)
    end;
array(Usage, R) when ?PAGE(Usage) =:= ?ERX_HID_USAGE_PAGE_BUTTON ->
    case erx_abi_translations:hid_button_key(?ID(Usage)) of
        none -> R;
        Code -> R#report{held = [Code | R#report.held]}
    end;
array(_, R) -> R.

key(Usage, R) ->
    case erx_abi_translations:hid_keyboard_key(?ID(Usage)) of
        none -> R#report{unmapped = R#report.unmapped + 1};
        Code -> R#report{held = [Code | R#report.held]}
    end.

%% Clamped to the logical range and spread across the record's axis, as the
%% virtio-input driver does (docs/design-display.md, "The display device").
normalized(V, #{min := Min, max := Max}) ->
    (clamp(V, Min, Max) - Min) * ?ERX_INPUT_AXIS_MAX div (Max - Min).

%% Value i of a variable field has usage i of its ranges, flattened, or the last one;
%% a field with no usage has none.
variable_usage(#{usages := []}, _I) -> none;
variable_usage(#{usages := Usages}, I) ->
    case nth_usage(Usages, I) of
        none -> element(2, lists:last(Usages));
        Usage -> Usage
    end.

%% An array value v names usage v - min of the ranges, flattened, or none.
array_usage(#{usages := Usages, min := Min}, V) when V >= Min -> nth_usage(Usages, V - Min);
array_usage(_, _) -> none.

nth_usage([], _) -> none;
nth_usage([{Lo, Hi} | _], I) when I =< Hi - Lo -> Lo + I;
nth_usage([{Lo, Hi} | Rest], I) -> nth_usage(Rest, I - (Hi - Lo + 1)).
