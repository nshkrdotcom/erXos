%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_db).
-moduledoc """
The attribute table (docs/design-bluetooth.md, "One table, one gate" and "The attribute
table"): a pure function of the services the manifest selects, built once when the
Bluetooth domain starts and never changed while it lives.

`build/1` lays out the GAP service, with Device Name and Appearance, read `open` (Vol 3
Part C, 12.1 and 12.2); the GATT service, with Service Changed, `indicate open`, and its
Client Characteristic Configuration (Part G, 7.1); then each served service in the order
of its name. A service is its declaration (Part G, 3.1); each characteristic its
declaration, its value and, when it allows `notify` or `indicate`, one Client
Characteristic Configuration (3.3), readable `open` and writable at the level of the
characteristic's `notify` or `indicate`, which the declarations give one level between
them. Handles run from 1 in that order.

Each attribute's value is a constant, for the declarations; the characteristic's, which
the ATT server reads from the values the handlers last set, or its declared initial value;
or the link's configuration of a characteristic. A service's group ends at its last
attribute, and a characteristic's at its last descriptor (Part G, 2.5.3). The table's hash,
SHA-256 over every attribute's handle and type and every declaration's value, in table
order, names it.

Its input is trusted configuration, a set of `erx_gatt_decl`'s terms, checked when the
declarations are generated and the manifest is built (docs/design-bluetooth.md,
"Declarations: `abi/gatt`"), so it is not checked again here. The one fact only the
layout knows, how many handles the table takes, is checked here, where the handles are
given: `build/1` fails with `{handles_past_0xffff, Count}` on a table of more than 0xFFFF
attributes, since ATT names a handle in 16 bits. (Part F 3.2.2, ATT's handle range, was
not read; 0xFFFF is the 16-bit field's last value.)
""".

-include("generated/erx_abi.hrl").

-export([build/1, lookup/2, range/3, characteristic/2, hash/1, service_changed/0]).
-export_type([table/0, attribute/0, service/0, characteristic/0, key/0, access/0, source/0, char_info/0]).

-type level() :: erx_gatt_gate:level().
-type access() :: read | write | write_without_response | notify | indicate.
-doc "A characteristic's name in the table: its service's and its own.".
-type key() :: {Service :: atom(), Char :: atom()}.

-doc "A service as `erx_gatt_decl` declares it: UUIDs as ATT carries them.".
-type service() :: #{name := atom(), uuid := erx_att:uuid(), characteristics := [characteristic()]}.
-type characteristic() :: #{name := atom(), uuid := erx_att:uuid(), max := 0..?ERX_ATT_VALUE_MAX,
                            access := #{access() => level()}, value => binary()}.

-doc """
Where an attribute's value comes from: a constant; the characteristic's value, `Initial`
until a handler sets one; or the link's configuration of the characteristic.
""".
-type source() :: {constant, binary()} | {value, key(), Initial :: binary()} | {configuration, key()}.
-doc """
One attribute. `read`, `write` and `command` (Write Without Response) are the level each
access requires, or `none` where it is not allowed; `max` bounds a written value.
""".
-type attribute() :: #{handle := erx_att:handle(), type := erx_att:uuid(), source := source(),
                       read := none | level(), write := none | level(), command := none | level(),
                       max := 0..?ERX_ATT_VALUE_MAX, group_end := erx_att:handle()}.
-doc "What a notification needs of a characteristic: its handles and its two levels.".
-type char_info() :: #{value := erx_att:handle(), configuration := none | erx_att:handle(),
                       notify := none | level(), indicate := none | level()}.
-opaque table() :: #{attributes := tuple(), characteristics := #{key() => char_info()}, hash := <<_:256>>}.

-doc "The table of the served `Services`, in any order.".
-spec build([service()]) -> table().
build(Services) ->
    Sorted = lists:sort(fun(#{name := A}, #{name := B}) -> A =< B end, Services),
    {Laid, _Next} = lists:mapfoldl(fun service/2, 1, [gap(), gatt() | Sorted]),
    {Attributes, Infos} = lists:unzip(Laid),
    Tuple = list_to_tuple(lists:append(Attributes)),
    tuple_size(Tuple) =< 16#FFFF orelse error({handles_past_0xffff, tuple_size(Tuple)}),
    #{attributes => Tuple, characteristics => maps:from_list(lists:append(Infos)),
      hash => layout_hash(Tuple)}.

-doc "The attribute at `Handle`.".
-spec lookup(erx_att:handle(), table()) -> {ok, attribute()} | error.
lookup(Handle, #{attributes := Attributes}) when Handle >= 1, Handle =< tuple_size(Attributes) ->
    {ok, element(Handle, Attributes)};
lookup(_Handle, _Table) ->
    error.

-doc "The attributes from `Start` to `End`, in handle order; `Start` is at least 1, and may be past the table.".
-spec range(erx_att:handle(), erx_att:handle(), table()) -> [attribute()].
range(Start, End, #{attributes := Attributes}) ->
    [element(Handle, Attributes) || Handle <- lists:seq(Start, max(Start - 1, min(End, tuple_size(Attributes))))].

-doc "The characteristic named `Key`.".
-spec characteristic(key(), table()) -> {ok, char_info()} | error.
characteristic(Key, #{characteristics := Characteristics}) ->
    maps:find(Key, Characteristics).

-doc "The table's hash.".
-spec hash(table()) -> <<_:256>>.
hash(#{hash := Hash}) -> Hash.

-doc """
The key of GATT's Service Changed characteristic (Part G, 7.1), which every table holds;
its value is the first and last handle of the range that changed.
""".
-spec service_changed() -> key().
service_changed() -> {gatt, service_changed}.

%% GAP's service (Part C, 12.1 and 12.2) and GATT's (Part G, 7.1), declared as any other;
%% GATT's names are service_changed/0's.
gap() ->
    #{name => gap, uuid => <<?ERX_GATT_UUID_GAP_SERVICE:16/little>>,
      characteristics => [#{name => device_name, uuid => <<?ERX_GATT_UUID_DEVICE_NAME:16/little>>,
                            max => ?ERX_GAP_DEVICE_NAME_MAX, access => #{read => open}},
                          #{name => appearance, uuid => <<?ERX_GATT_UUID_APPEARANCE:16/little>>,
                            max => 2, access => #{read => open}, value => <<0, 0>>}]}.

gatt() ->
    {Service, ServiceChanged} = service_changed(),
    #{name => Service, uuid => <<?ERX_GATT_UUID_GATT_SERVICE:16/little>>,
      characteristics => [#{name => ServiceChanged, uuid => <<?ERX_GATT_UUID_SERVICE_CHANGED:16/little>>,
                            max => 4, access => #{indicate => open}}]}.

%% A service's attributes from handle `First` with what notifications need of its
%% characteristics, and the handle after them.
service(#{name := Name, uuid := Uuid, characteristics := Chars}, First) ->
    {Laid, Next} = lists:mapfoldl(fun(Char, Handle) -> characteristic_attributes(Name, Char, Handle) end,
                                  First + 1, Chars),
    {CharAttributes, Infos} = lists:unzip(Laid),
    Declaration = (constant(First, <<?ERX_GATT_UUID_PRIMARY_SERVICE:16/little>>, Uuid))#{group_end := Next - 1},
    {{[Declaration | lists:append(CharAttributes)], Infos}, Next}.

%% A characteristic's declaration, value and configuration from handle `First` (Part G, 3.3).
characteristic_attributes(Service, #{name := Name, uuid := Uuid, max := Max, access := Access} = Char, First) ->
    Key = {Service, Name},
    ValueHandle = First + 1,
    Subscribe = subscribe_level(Access),
    Configurations = [#{handle => ValueHandle + 1, type => <<?ERX_GATT_UUID_CLIENT_CONFIGURATION:16/little>>,
                        source => {configuration, Key}, read => open, write => Subscribe, command => none,
                        max => 2, group_end => ValueHandle + 1}
                      || Subscribe =/= none],
    Last = ValueHandle + length(Configurations),
    Declaration = (constant(First, <<?ERX_GATT_UUID_CHARACTERISTIC:16/little>>,
                            <<(properties(Access)), ValueHandle:16/little, Uuid/binary>>))#{group_end := Last},
    Value = #{handle => ValueHandle, type => Uuid, source => {value, Key, maps:get(value, Char, <<>>)},
              read => level(read, Access), write => level(write, Access),
              command => level(write_without_response, Access), max => Max, group_end => ValueHandle},
    Info = #{value => ValueHandle, configuration => case Configurations of [_] -> ValueHandle + 1; [] -> none end,
             notify => level(notify, Access), indicate => level(indicate, Access)},
    {{[Declaration, Value | Configurations], {Key, Info}}, Last + 1}.

%% SHA-256 over what a client keeps of the table, in table order: every attribute's handle
%% and type, and a declaration's value, the type and the value led by their lengths so
%% that no two tables give one input. A maximum, a level and a characteristic's value are
%% not kept, so changing one keeps the hash.
layout_hash(Attributes) ->
    erx_bytes:sha256(<< <<Handle:16/little, (byte_size(Type)), Type/binary,
                          (byte_size(Value)):16/little, Value/binary>>
                        || #{handle := Handle, type := Type, source := Source} <- tuple_to_list(Attributes),
                           Value <- [declared_value(Source)] >>).

declared_value({constant, Value}) -> Value;
declared_value(_Source) -> <<>>.

%% A declaration: read openly, never written.
constant(Handle, Type, Value) ->
    #{handle => Handle, type => Type, source => {constant, Value}, read => open, write => none, command => none,
      max => byte_size(Value), group_end => Handle}.

level(Kind, Access) -> maps:get(Kind, Access, none).

%% The level of the configuration's writes: the one of notify or indicate the declaration gives.
subscribe_level(#{notify := Level}) -> Level;
subscribe_level(#{indicate := Level}) -> Level;
subscribe_level(_Access) -> none.

%% A declaration's Characteristic Properties (Part G, 3.3.1.1, Table 3.5).
properties(Access) ->
    lists:foldl(fun({Kind, Bit}, Bits) -> Bits bor case maps:is_key(Kind, Access) of true -> Bit; false -> 0 end end,
                0, [{read, ?ERX_GATT_PROPERTY_READ}, {write_without_response, ?ERX_GATT_PROPERTY_WRITE_WITHOUT_RESPONSE},
                    {write, ?ERX_GATT_PROPERTY_WRITE}, {notify, ?ERX_GATT_PROPERTY_NOTIFY},
                    {indicate, ?ERX_GATT_PROPERTY_INDICATE}]).

