%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hid_desc).
-moduledoc """
The HID report descriptor's parser (docs/design-usb.md, "The report
descriptor"): parse/1 turns the bytes a HID interface returns for
GET_DESCRIPTOR(report) into a layout, the input fields of each report
and the length of each report, which `erx_hid_core` folds reports
against.

It takes the decisions of FreeBSD's item parser, `hid_get_item` in
`sys/dev/hid/hid.c` (release/15.1.0-p6, 95719d8a): short items of 0, 1,
2 or 4 bytes of data, the prefix holding tag, type and size
(lines 305-318); global items kept in a state that Push and Pop save and
restore on a stack of four levels, the current one included
(lines 446-472); local items, the usages, cleared at each main item;
a Usage Minimum and Maximum adding their range once both are set and
the minimum is not above the maximum, a Usage clearing a half-set range
(lines 483-546); a usage of fewer than four bytes taking the current
usage page as its upper half; and each kind of main item, Input, Output
and Feature, at a bit position of its own for each report id, as a parse
for one kind advances only that kind's position (lines 285-289, 117-168).
Output and Feature items are parsed for their positions and otherwise
ignored.

Where FreeBSD stops parsing and keeps what it read, at a fourth push, a
pop with nothing pushed and an End Collection with nothing open
(lines 403-406, 446-472), this module refuses the descriptor, so a layout
is never built from part of one. Where FreeBSD carries on past a bound
by dropping or cutting (a 65th usage of one main item, line 497; a 16th
report id, whose position it sets to zero, line 166, id 0 holding its
first slot, so 15 named ids; a variable field's count above 2048, cut,
lines 365-370), this module refuses too. It adds its own bounds: a
descriptor of at most `hid_report_descriptor_max` bytes, an input field
of at most 32 bits a value, an input report of at most the 1 KiB
interrupt buffer with its report-id byte, a report id from 1 to 255, the
one byte a report carries it in (HID 1.11, section 6.2.2.7, reserves
id 0), and no input field both outside and inside a numbered report,
since a report then cannot say which it is. Each bound comes from
`abi/formats/hid.txt`.

These cases differ from FreeBSD by intent and are named here for the
oracle test of the verification table: an item cut off by the end of the
descriptor is refused, where FreeBSD reads its missing bytes as zero; a
long item is skipped by its one-byte data size (HID 1.11,
section 6.2.2.3), where FreeBSD reads two size bytes; Push and Pop save
and restore the globals alone, so the open collections and a half-set
usage range are not on the stack, where FreeBSD keeps the collection
depth and the range's halves in the pushed item; Pop restores the report
id with the other globals and the position is that id's own, where
FreeBSD keeps the inner id's position; and a field with no usage of its
own has none, where FreeBSD reports usage 0. A variable field with fewer
usages than values gives its later values the field's last usage, as
FreeBSD does. An array field keeps every usage range, where FreeBSD's
item keeps its first usage, at most eight range minimums and the last
range. A usage range may cross pages, through four-byte Usage Minimum
and Maximum items, and a field's logical minimum may be above its
maximum; the layout leaves both as the descriptor says.

Everything here reads what a device wrote, so it is untrusted input:
parse/1 answers `{ok, Layout}` or `{error, Reason}` and never raises,
which `test/erlang/erx_hid_desc_fuzz.erl` checks. Every refusal leaves
through one `throw` caught in parse/1.
""".

-export([parse/1]).

-export_type([layout/0, report/0, field/0, usage/0, report_id/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc "A usage with its page: the page in bits 31-16, the usage in bits 15-0.".
-type usage() :: 0..16#ffffffff.

-doc "A report's id, 0 where the descriptor names none.".
-type report_id() :: 0..255.

-doc """
One input field: `count` values of `size` bits from bit `offset` of the
report, after its id byte. A variable field's value i has usage i of the
ranges, flattened, or the last one; an array field's value v names usage
`v - min` of them, as section 6.2.2.4 of HID 1.11 says.
""".
-type field() :: #{offset := non_neg_integer(),
                   size := 1..?ERX_HID_FIELD_BITS_MAX,
                   count := 1..?ERX_HID_REPORT_COUNT_MAX,
                   min := integer(),
                   max := integer(),
                   usages := [{usage(), usage()}],
                   variable := boolean(),
                   relative := boolean()}.

-doc "One report's input fields in order and its length in bytes, without its id byte.".
-type report() :: #{fields := [field()], bytes := 1..?ERX_HID_INPUT_REPORT_MAX}.

-doc """
The input reports by id; `numbered` when they carry an id byte first, in
which case no report has id 0; `largest` the longest report's bytes,
without its id byte, 0 when there is no input report.
""".
-type layout() :: #{reports := #{report_id() => report()},
                    numbered := boolean(),
                    largest := 0..?ERX_HID_INPUT_REPORT_MAX}.

-type reason() :: too_long | truncated | push_too_deep | pop_without_push
                | unbalanced_collection | too_many_usages | too_many_report_ids
                | bad_report_id | report_count_too_large | field_too_wide
                | report_too_large | mixed_report_ids.

-type kind() :: input | output | feature.

%% The global items the layout reads; Push saves them and Pop restores them.
-record(globals, {page = 0 :: 0..16#ffff,
                  min = 0 :: integer(),
                  max = 0 :: integer(),
                  size = 0 :: non_neg_integer(),
                  count = 0 :: non_neg_integer(),
                  id = 0 :: report_id()}).

%% The local items of the next main item: its usage ranges, newest first, and the
%% halves of a range not yet complete, as hid.c's usage_minimum, usage_maximum and
%% susage hold them.
-record(locals, {usages = [] :: [{usage(), usage()}],
                 minimum = 0 :: usage(),
                 maximum = 0 :: usage(),
                 pending = none :: none | minimum | maximum}).

%% The parse: the globals, the saved globals, newest first, the locals, the open
%% collections, each kind's bit position by report id, the input fields by report id,
%% newest first, and the named ids seen.
-record(parse, {globals = #globals{} :: #globals{},
                stack = [] :: [#globals{}],
                locals = #locals{} :: #locals{},
                collections = 0 :: non_neg_integer(),
                positions = #{} :: #{{kind(), report_id()} => non_neg_integer()},
                fields = #{} :: #{report_id() => [field()]},
                ids = [] :: [1..255]}).

-doc "The layout of a report descriptor, or the reason it is refused.".
-spec parse(binary()) -> {ok, layout()} | {error, reason()}.
parse(Bytes) when byte_size(Bytes) > ?ERX_HID_REPORT_DESCRIPTOR_MAX ->
    {error, too_long};
parse(Bytes) when is_binary(Bytes) ->
    try
        {ok, layout(items(Bytes, #parse{}))}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

-spec refuse(reason()) -> no_return().
refuse(Reason) -> throw({?MODULE, Reason}).

check(true, _Reason) -> ok;
check(false, Reason) -> refuse(Reason).

%% One item at a time. A long item is skipped whole; a short item's data is its
%% value, unsigned and sign-extended from its size.
items(<<>>, P) ->
    P;
items(<<?ERX_HID_ITEM_LONG, Size, _Tag, _:Size/binary, Rest/binary>>, P) ->
    items(Rest, P);
items(<<?ERX_HID_ITEM_LONG, _/binary>>, _P) ->
    refuse(truncated);
items(<<Tag:4, Type:2, SizeCode:2, Rest/binary>>, P) ->
    Bits = 8 * data_bytes(SizeCode),
    case Rest of
        <<Unsigned:Bits/little, Next/binary>> ->
            <<Signed:Bits/little-signed>> = <<Unsigned:Bits/little>>,
            items(Next, item(Type, Tag, {Bits, Unsigned, Signed}, P));
        _ ->
            refuse(truncated)
    end.

data_bytes(3) -> 4;
data_bytes(Size) -> Size.

item(?ERX_HID_ITEM_TYPE_MAIN, Tag, {_, Unsigned, _}, P) ->
    main(Tag, Unsigned, P);
item(?ERX_HID_ITEM_TYPE_GLOBAL, Tag, Value, P) ->
    global(Tag, Value, P);
item(?ERX_HID_ITEM_TYPE_LOCAL, Tag, Value, P) ->
    P#parse{locals = usage_item(Tag, Value, P#parse.globals, P#parse.locals)};
item(_Reserved, _Tag, _Value, P) ->
    P.

%% A main item of a kind the layout keeps places its field and clears the locals; a
%% collection's start and end count and clear them; another main tag sets nothing, as
%% in hid.c, where it leaves the locals as they are.
main(?ERX_HID_MAIN_TAG_INPUT, Flags, P) -> cleared(field(input, Flags, P));
main(?ERX_HID_MAIN_TAG_OUTPUT, Flags, P) -> cleared(field(output, Flags, P));
main(?ERX_HID_MAIN_TAG_FEATURE, Flags, P) -> cleared(field(feature, Flags, P));
main(?ERX_HID_MAIN_TAG_COLLECTION, _, P) ->
    cleared(P#parse{collections = P#parse.collections + 1});
main(?ERX_HID_MAIN_TAG_END_COLLECTION, _, #parse{collections = 0}) ->
    refuse(unbalanced_collection);
main(?ERX_HID_MAIN_TAG_END_COLLECTION, _, P) ->
    cleared(P#parse{collections = P#parse.collections - 1});
main(_Other, _, P) ->
    P.

cleared(P) -> P#parse{locals = #locals{}}.

%% Places count values of size bits at the kind's position for the current id. Only a
%% non-constant input field with bits is kept; every field moves its kind's position.
field(_Kind, _Flags, #parse{globals = #globals{count = Count}}) when Count > ?ERX_HID_REPORT_COUNT_MAX ->
    refuse(report_count_too_large);
field(Kind, Flags, P = #parse{globals = G, positions = Positions}) ->
    #globals{size = Size, count = Count, id = Id} = G,
    Key = {Kind, Id},
    Offset = maps:get(Key, Positions, 0),
    Kept = Kind =:= input andalso Size * Count > 0 andalso Flags band ?ERX_HID_FIELD_CONSTANT =:= 0,
    Next = P#parse{positions = Positions#{Key => Offset + Size * Count}},
    case Kept of
        true when Size > ?ERX_HID_FIELD_BITS_MAX ->
            refuse(field_too_wide);
        true ->
            Field = #{offset => Offset, size => Size, count => Count, min => G#globals.min,
                      max => G#globals.max, usages => lists:reverse(P#parse.locals#locals.usages),
                      variable => Flags band ?ERX_HID_FIELD_VARIABLE =/= 0,
                      relative => Flags band ?ERX_HID_FIELD_RELATIVE =/= 0},
            Next#parse{fields = maps:update_with(Id, fun(Fields) -> [Field | Fields] end, [Field],
                                                 P#parse.fields)};
        false ->
            Next
    end.

%% Push saves a copy of the globals and keeps them; Pop replaces them with the copy
%% saved last. hid.c stops parsing at the push that would make a fourth level (line 448). A
%% report id is one byte of a report, and a named id is counted against FreeBSD's
%% slots, the first of which id 0 holds.
global(?ERX_HID_GLOBAL_TAG_PUSH, _, #parse{stack = Stack}) when length(Stack) + 1 >= ?ERX_HID_PUSH_LEVELS_MAX ->
    refuse(push_too_deep);
global(?ERX_HID_GLOBAL_TAG_PUSH, _, P = #parse{globals = G, stack = Stack}) ->
    P#parse{stack = [G | Stack]};
global(?ERX_HID_GLOBAL_TAG_POP, _, #parse{stack = []}) ->
    refuse(pop_without_push);
global(?ERX_HID_GLOBAL_TAG_POP, _, P = #parse{stack = [Saved | Stack]}) ->
    P#parse{globals = Saved, stack = Stack};
global(?ERX_HID_GLOBAL_TAG_REPORT_ID, {_, Id, _}, P = #parse{globals = G, ids = Ids}) when Id >= 1, Id =< 255 ->
    Named = lists:member(Id, Ids),
    check(Named orelse length(Ids) + 1 < ?ERX_HID_REPORT_IDS_MAX, too_many_report_ids),
    P#parse{globals = G#globals{id = Id}, ids = lists:usort([Id | Ids])};
global(?ERX_HID_GLOBAL_TAG_REPORT_ID, _, _P) ->
    refuse(bad_report_id);
global(Tag, Value, P = #parse{globals = G}) ->
    P#parse{globals = value(Tag, Value, G)}.

%% Report Size and Report Count are unsigned, the logical bounds signed, as hid.c
%% reads them; the usage page is the low half of its value.
value(?ERX_HID_GLOBAL_TAG_USAGE_PAGE, {_, Unsigned, _}, G) -> G#globals{page = Unsigned band 16#ffff};
value(?ERX_HID_GLOBAL_TAG_LOGICAL_MINIMUM, {_, _, Signed}, G) -> G#globals{min = Signed};
value(?ERX_HID_GLOBAL_TAG_LOGICAL_MAXIMUM, {_, _, Signed}, G) -> G#globals{max = Signed};
value(?ERX_HID_GLOBAL_TAG_REPORT_SIZE, {_, Unsigned, _}, G) -> G#globals{size = Unsigned};
value(?ERX_HID_GLOBAL_TAG_REPORT_COUNT, {_, Unsigned, _}, G) -> G#globals{count = Unsigned};
value(_Other, _, G) -> G.

%% A usage of fewer than four bytes is on the current page; one of four names its own.
usage_item(Tag, {Bits, Unsigned, _}, G, L) ->
    local(Tag, extended(Bits, Unsigned, G), L).

extended(32, Unsigned, _G) -> Unsigned;
extended(_Bits, Unsigned, #globals{page = Page}) -> (Page bsl 16) bor Unsigned.

local(?ERX_HID_LOCAL_TAG_USAGE, Usage, L) ->
    L#locals{usages = added({Usage, Usage}, L#locals.usages), pending = none};
local(?ERX_HID_LOCAL_TAG_USAGE_MINIMUM, Minimum, L = #locals{pending = maximum}) ->
    ranged(L#locals{minimum = Minimum});
local(?ERX_HID_LOCAL_TAG_USAGE_MINIMUM, Minimum, L) ->
    L#locals{minimum = Minimum, pending = minimum};
local(?ERX_HID_LOCAL_TAG_USAGE_MAXIMUM, Maximum, L = #locals{pending = minimum}) ->
    ranged(L#locals{maximum = Maximum});
local(?ERX_HID_LOCAL_TAG_USAGE_MAXIMUM, Maximum, L) ->
    L#locals{maximum = Maximum, pending = maximum};
local(_Other, _, L) ->
    L.

%% Both halves set: the range is added unless its minimum is above its maximum, which
%% hid.c drops (line 524).
ranged(L = #locals{minimum = Minimum, maximum = Maximum}) when Minimum =< Maximum ->
    L#locals{usages = added({Minimum, Maximum}, L#locals.usages), pending = none};
ranged(L) ->
    L#locals{pending = none}.

added(_Range, Usages) when length(Usages) >= ?ERX_HID_USAGES_MAX -> refuse(too_many_usages);
added(Range, Usages) -> [Range | Usages].

%% The layout: each id with input bits, its fields in order and its length.
layout(#parse{positions = Positions, fields = Fields}) ->
    Reports = maps:from_list([{Id, #{fields => lists:reverse(maps:get(Id, Fields, [])),
                                     bytes => (Bits + 7) div 8}}
                              || {input, Id} := Bits <- Positions, Bits > 0]),
    Numbered = lists:any(fun(Id) -> Id =/= 0 end, maps:keys(Reports)),
    check(not (Numbered andalso is_map_key(0, Reports)), mixed_report_ids),
    IdByte = case Numbered of true -> 1; false -> 0 end,
    Largest = lists:max([0 | [Bytes || _ := #{bytes := Bytes} <- Reports]]),
    check(Largest + IdByte =< ?ERX_HID_INPUT_REPORT_MAX, report_too_large),
    #{reports => Reports, numbered => Numbered, largest => Largest}.
