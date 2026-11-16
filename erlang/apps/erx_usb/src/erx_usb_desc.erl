%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_desc).
-moduledoc """
The USB descriptor decoder (docs/design-usb.md, "Descriptors"): turns the
bytes a device returns to GET_DESCRIPTOR during enumeration into maps the
claim and the bus core read. It decodes the device descriptor, a
configuration with its interface, endpoint, SuperSpeed endpoint companion
and HID descriptors, a hub descriptor, a string descriptor and the
language table.

A configuration is walked one descriptor at a time over its first
`wTotalLength` bytes, never over the bytes received past them, and each
descriptor must lie wholly inside them with a `bLength` of at least 2,
the smallest header. FreeBSD's walk stops at a descriptor shorter than 3
(`usb_desc_foreach`, sys/dev/usb/usb_parse.c:96-110, release/15.1.0,
95719d8a); this one refuses a descriptor shorter than 2 and skips a
descriptor of a type it does not use, so a 2-byte vendor descriptor ends
nothing. The walk builds one map from `{interface number, alternate
setting}` to that setting, so a second definition of a key refuses the
configuration instead of shadowing the first. Each endpoint descriptor
belongs to the interface descriptor before it, and `bNumEndpoints` is not
read; a SuperSpeed endpoint companion belongs to the endpoint descriptor
just before it, and a HID descriptor to the HID interface (class 03h)
before it, one per setting. Type 21h is HID's only under a HID
interface; before any interface or under another class it is not HID's,
such as a DFU functional or CCID class descriptor, and is skipped, so
such an interface of a composite device leaves its HID function be. An
endpoint whose number is 0, in either direction and whatever its
reserved bits 6:4 hold, refuses the configuration, since its device
context index would be EP0's. An endpoint's address is kept as its
direction and number alone, so two addresses that differ only in the
reserved bits are one pipe.

A hub descriptor arrives on its own request after the configuration
(enumeration step 7) and is decoded by hub/1, so the walk skips one like
any other class descriptor it does not use; hub/1 reads only the 7-byte
head, which holds every field the stack uses, so a read cut short of
`bLength`, such as the first read of a hub of 8 ports or more, is
enough. A string's UTF-16LE is decoded
to UTF-8 with an unpaired surrogate replaced by U+FFFD, and an odd
trailing byte is dropped, as FreeBSD reads `bLength / 2 - 1` code units
(`usbd_req_get_string_any`, sys/dev/usb/usb_request.c:1151).

Every bound comes from `abi/formats/usb.txt` and `abi/formats/hid.txt`.
Everything here reads what a device wrote, so it is untrusted input: each
decoder answers `{ok, Value}` or `{error, Reason}` and never raises, which
`test/erlang/erx_usb_desc_fuzz.erl` checks, and every refusal leaves
through one `throw` caught in decoded/1. No atom is made from input.
""".

-export([device/1, configuration/1, hub/1, string/1, languages/1, language/1]).

-export_type([device/0, configuration/0, setting/0, endpoint/0, companion/0, hid/0,
              hub/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc "The device descriptor's fields; each `*_index` names a string descriptor, 0 for none.".
-type device() :: #{usb := 0..16#ffff,
                    class := byte(),
                    subclass := byte(),
                    protocol := byte(),
                    max_packet_size0 := byte(),
                    vendor := 0..16#ffff,
                    product := 0..16#ffff,
                    release := 0..16#ffff,
                    manufacturer_index := byte(),
                    product_index := byte(),
                    serial_index := byte(),
                    configurations := byte()}.

-doc "A SuperSpeed endpoint companion's fields, `max_burst` zero-based as the device wrote it.".
-type companion() :: #{max_burst := byte(),
                       attributes := byte(),
                       bytes_per_interval := 0..16#ffff}.

-doc """
An endpoint: its address as direction (bit 7) and number (bits 3:0), its
transfer type, `wMaxPacketSize` whole as the device wrote it, `bInterval`,
and its companion when one followed it.
""".
-type endpoint() :: #{address := byte(),
                      type := control | isochronous | bulk | interrupt,
                      max_packet := 0..16#ffff,
                      interval := byte(),
                      companion := none | companion()}.

-doc "A HID descriptor: the length of the report descriptor it names.".
-type hid() :: #{report_length := 0..16#ffff}.

-doc "One alternate setting of one interface: its class triple, its endpoints in order and its HID descriptor.".
-type setting() :: #{class := byte(),
                     subclass := byte(),
                     protocol := byte(),
                     endpoints := [endpoint()],
                     hid := none | hid()}.

-doc "A configuration: its value for SET_CONFIGURATION, attributes, power and settings.".
-type configuration() :: #{value := byte(),
                           attributes := byte(),
                           max_power := byte(),
                           settings := #{{byte(), byte()} => setting()}}.

-doc "A hub descriptor: its port count, the think time of its transaction translator and its power-on-to-good time in 2 ms units.".
-type hub() :: #{ports := 1..?ERX_USB_HUB_PORTS_MAX,
                 think_time := 0..3,
                 power_good := byte()}.

-type reason() :: descriptor_too_long | malformed_descriptor | duplicate_interface
                | endpoint_zero | too_many_ports.

%% The walk over a configuration's descriptors: the settings by key, each with its
%% endpoints newest first; the key of the interface descriptor last seen; and whether
%% the descriptor just before is an endpoint descriptor, which a companion needs;
%% walk/2 alone sets it, from each descriptor's type.
-record(walk, {settings = #{} :: #{{byte(), byte()} => setting()},
               current = none :: none | {byte(), byte()},
               after_endpoint = false :: boolean()}).

-doc "The device descriptor, exactly 18 bytes of type 1.".
-spec device(binary()) -> {ok, device()} | {error, reason()}.
device(Bytes) when is_binary(Bytes) -> decoded(fun() -> device_fields(Bytes) end).

-doc """
A configuration from its header on: the header must be 9 bytes of type 2
with `wTotalLength` from 9 to `usb_config_max`, and the bytes given must
hold all `wTotalLength`; bytes past it are not read.
""".
-spec configuration(binary()) -> {ok, configuration()} | {error, reason()}.
configuration(Bytes) when is_binary(Bytes) -> decoded(fun() -> walk_configuration(Bytes) end).

-doc "A hub descriptor's 7-byte head, its `bLength` at least 7, with a port count from 1 to `usb_hub_ports_max`.".
-spec hub(binary()) -> {ok, hub()} | {error, reason()}.
hub(Bytes) when is_binary(Bytes) -> decoded(fun() -> hub_fields(Bytes) end).

-doc "A string descriptor's text, as UTF-8.".
-spec string(binary()) -> {ok, unicode:unicode_binary()} | {error, reason()}.
string(Bytes) when is_binary(Bytes) -> decoded(fun() -> utf8(string_body(Bytes), <<>>) end).

-doc "The language table, string descriptor 0: its language ids in order.".
-spec languages(binary()) -> {ok, [0..16#ffff]} | {error, reason()}.
languages(Bytes) when is_binary(Bytes) ->
    decoded(fun() -> [Id || <<Id:16/little>> <= string_body(Bytes)] end).

-doc """
The language the strings are read in: the table's first English one,
whose primary language is 09h, and otherwise its first, as FreeBSD
chooses (sys/dev/usb/usb_device.c:1717-1728, as `abi/formats/usb.txt`
cites it); `none` for an empty table.
""".
-spec language([0..16#ffff]) -> none | 0..16#ffff.
language([]) ->
    none;
language([First | _] = Table) ->
    English = [Id || Id <- Table,
                     Id band ?ERX_USB_LANGUAGE_PRIMARY_MASK =:= ?ERX_USB_LANGUAGE_ENGLISH],
    hd(English ++ [First]).

-spec decoded(fun(() -> Value)) -> {ok, Value} | {error, reason()}.
decoded(Decode) ->
    try
        {ok, Decode()}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

-spec refuse(reason()) -> no_return().
refuse(Reason) -> throw({?MODULE, Reason}).

check(true, _Reason) -> ok;
check(false, Reason) -> refuse(Reason).

device_fields(<<Length, ?ERX_USB_DESCRIPTOR_TYPE_DEVICE, Usb:16/little, Class, Subclass, Protocol,
                MaxPacket0, Vendor:16/little, Product:16/little, Release:16/little,
                Manufacturer, ProductIndex, Serial, Configurations>> = Bytes)
  when Length =:= ?ERX_USB_DEVICE_DESCRIPTOR_SIZE,
       byte_size(Bytes) =:= ?ERX_USB_DEVICE_DESCRIPTOR_SIZE ->
    #{usb => Usb, class => Class, subclass => Subclass, protocol => Protocol,
      max_packet_size0 => MaxPacket0, vendor => Vendor, product => Product, release => Release,
      manufacturer_index => Manufacturer, product_index => ProductIndex, serial_index => Serial,
      configurations => Configurations};
device_fields(_) ->
    refuse(malformed_descriptor).

%% The header's own wTotalLength bounds the walk; too long is told apart from
%% malformed, since a device past the bound is refused for that bound.
walk_configuration(<<Length, ?ERX_USB_DESCRIPTOR_TYPE_CONFIGURATION, Total:16/little, _Interfaces,
                     Value, _Name, Attributes, MaxPower, _/binary>> = Bytes)
  when Length =:= ?ERX_USB_CONFIGURATION_DESCRIPTOR_SIZE ->
    check(Total =< ?ERX_USB_CONFIG_MAX, descriptor_too_long),
    check(Total >= Length andalso Total =< byte_size(Bytes), malformed_descriptor),
    <<_:Length/binary, Body:(Total - Length)/binary, _Unread/binary>> = Bytes,
    #walk{settings = Settings} = walk(Body, #walk{}),
    #{value => Value, attributes => Attributes, max_power => MaxPower,
      settings => maps:map(fun(_Key, S = #{endpoints := Es}) -> S#{endpoints := lists:reverse(Es)} end,
                           Settings)};
walk_configuration(_) ->
    refuse(malformed_descriptor).

walk(<<>>, W) ->
    W;
walk(<<Length, Type, _/binary>> = Bytes, W)
  when Length >= ?ERX_USB_DESCRIPTOR_HEADER_SIZE, Length =< byte_size(Bytes) ->
    <<Descriptor:Length/binary, Rest/binary>> = Bytes,
    Next = descriptor(Type, Descriptor, W),
    walk(Rest, Next#walk{after_endpoint = Type =:= ?ERX_USB_DESCRIPTOR_TYPE_ENDPOINT});
walk(_, _) ->
    refuse(malformed_descriptor).

%% Type 21h is the HID descriptor only under a HID interface; under another class it is
%% that class's own, and skipped.
descriptor(?ERX_USB_DESCRIPTOR_TYPE_INTERFACE, D, W) ->
    interface(at_least(D, ?ERX_USB_INTERFACE_DESCRIPTOR_SIZE), W);
descriptor(?ERX_USB_DESCRIPTOR_TYPE_ENDPOINT, D, W) ->
    endpoint(at_least(D, ?ERX_USB_ENDPOINT_DESCRIPTOR_SIZE), W);
descriptor(?ERX_USB_DESCRIPTOR_TYPE_SS_ENDPOINT_COMPANION, D, W) ->
    companion(at_least(D, ?ERX_USB_SS_ENDPOINT_COMPANION_SIZE), W);
descriptor(?ERX_HID_DESCRIPTOR_HID, D, W = #walk{current = Key, settings = Settings})
  when Key =/= none ->
    case map_get(Key, Settings) of
        #{class := ?ERX_USB_CLASS_HID} -> hid(at_least(D, ?ERX_HID_DESCRIPTOR_SIZE), W);
        _ -> W
    end;
descriptor(_Unused, _D, W) ->
    W.

at_least(D, Size) when byte_size(D) >= Size -> D;
at_least(_, _) -> refuse(malformed_descriptor).

interface(<<_, _, Number, Alternate, _Endpoints, Class, Subclass, Protocol, _/binary>>,
          W = #walk{settings = Settings}) ->
    Key = {Number, Alternate},
    check(not is_map_key(Key, Settings), duplicate_interface),
    Setting = #{class => Class, subclass => Subclass, protocol => Protocol, endpoints => [],
                hid => none},
    W#walk{settings = Settings#{Key => Setting}, current = Key}.

endpoint(_, #walk{current = none}) ->
    refuse(malformed_descriptor);
endpoint(<<_, _, Address, Attributes, MaxPacket:16/little, Interval, _/binary>>, W) ->
    check(Address band ?ERX_USB_ENDPOINT_NUMBER_MASK =/= 0, endpoint_zero),
    Endpoint = #{address => Address band (?ERX_USB_ENDPOINT_DIR_IN bor ?ERX_USB_ENDPOINT_NUMBER_MASK),
                 type => transfer_type(Attributes band ?ERX_USB_ENDPOINT_TYPE_MASK),
                 max_packet => MaxPacket, interval => Interval, companion => none},
    update(W, fun(S = #{endpoints := Es}) -> S#{endpoints := [Endpoint | Es]} end).

companion(_, #walk{after_endpoint = false}) ->
    refuse(malformed_descriptor);
companion(<<_, _, MaxBurst, Attributes, BytesPerInterval:16/little, _/binary>>, W) ->
    Companion = #{max_burst => MaxBurst, attributes => Attributes,
                  bytes_per_interval => BytesPerInterval},
    update(W, fun(S = #{endpoints := [E | Es]}) -> S#{endpoints := [E#{companion := Companion} | Es]} end).

%% One HID descriptor a setting, whose first class descriptor is the report descriptor.
hid(<<_, _, _Release:16/little, _Country, _Count, ?ERX_HID_DESCRIPTOR_REPORT, Length:16/little,
      _/binary>>, W) ->
    update(W, fun(S = #{hid := none}) -> S#{hid := #{report_length => Length}};
                 (_) -> refuse(malformed_descriptor)
              end);
hid(_, _) ->
    refuse(malformed_descriptor).

%% Applies Change to the current setting.
update(W = #walk{current = Key, settings = Settings}, Change) ->
    W#walk{settings = Settings#{Key := Change(map_get(Key, Settings))}}.

transfer_type(?ERX_USB_TRANSFER_TYPE_CONTROL) -> control;
transfer_type(?ERX_USB_TRANSFER_TYPE_ISOCHRONOUS) -> isochronous;
transfer_type(?ERX_USB_TRANSFER_TYPE_BULK) -> bulk;
transfer_type(?ERX_USB_TRANSFER_TYPE_INTERRUPT) -> interrupt.

%% Only the 7-byte head is read, so a read cut short of bLength is enough.
hub_fields(<<Length, ?ERX_USB_DESCRIPTOR_TYPE_HUB, Ports, Characteristics:16/little, PowerGood,
             _/binary>> = Bytes)
  when Length >= ?ERX_USB_HUB_DESCRIPTOR_HEAD, byte_size(Bytes) >= ?ERX_USB_HUB_DESCRIPTOR_HEAD ->
    check(Ports >= 1, malformed_descriptor),
    check(Ports =< ?ERX_USB_HUB_PORTS_MAX, too_many_ports),
    #{ports => Ports, power_good => PowerGood,
      think_time => (Characteristics band ?ERX_USB_HUB_TT_THINK_MASK) bsr ?ERX_USB_HUB_TT_THINK_SHIFT};
hub_fields(_) ->
    refuse(malformed_descriptor).

%% A string descriptor's whole UTF-16LE code units, an odd trailing byte dropped.
string_body(<<Length, ?ERX_USB_DESCRIPTOR_TYPE_STRING, _/binary>> = Bytes)
  when Length >= ?ERX_USB_DESCRIPTOR_HEADER_SIZE, Length =< byte_size(Bytes) ->
    Units = (Length - ?ERX_USB_DESCRIPTOR_HEADER_SIZE) div 2,
    <<_:?ERX_USB_DESCRIPTOR_HEADER_SIZE/binary, Body:Units/binary-unit:16, _/binary>> = Bytes,
    Body;
string_body(_) ->
    refuse(malformed_descriptor).

utf8(<<High:16/little, Low:16/little, Rest/binary>>, Text)
  when High >= 16#d800, High =< 16#dbff, Low >= 16#dc00, Low =< 16#dfff ->
    Code = 16#10000 + ((High - 16#d800) bsl 10) + (Low - 16#dc00),
    utf8(Rest, <<Text/binary, Code/utf8>>);
utf8(<<Unit:16/little, Rest/binary>>, Text) when Unit >= 16#d800, Unit =< 16#dfff ->
    utf8(Rest, <<Text/binary, 16#fffd/utf8>>);
utf8(<<Unit:16/little, Rest/binary>>, Text) ->
    utf8(Rest, <<Text/binary, Unit/utf8>>);
utf8(<<>>, Text) ->
    Text.
