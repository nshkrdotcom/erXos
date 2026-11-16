%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_adv).
-moduledoc """
The advertising and scan response data (docs/design-bluetooth.md, "Advertising"): a pure
function of the advertised service UUIDs, the name and the appearance, which the controller
process calls at its start, so every start computes the same bytes. Each is a run of AD
structures, a length, a type and its data (Vol 3 Part C, 11), at most 31 octets:

- the advertising data: the Flags (LE General Discoverable, BR/EDR not supported), then the
  complete list of 16-bit UUIDs and the complete list of 128-bit UUIDs, each only when it
  has a member;
- the scan response data: the complete local name, or the name shortened to what fits, then
  the appearance when it fits.

The UUIDs come from the configuration, which the manifest check holds to what fits, so
UUIDs that do not fit fail with `badarg`; the name is shortened rather than refused, at a
character boundary.
""".

-include("generated/erx_abi.hrl").

-export([data/1]).
-export_type([uuid/0, input/0]).

-doc "A service UUID: a 16-bit one, or a 128-bit one as its integer.".
-type uuid() :: 0..16#FFFF | 16#10000..(1 bsl 128 - 1).
-type input() :: #{uuids := [uuid()], name := unicode:unicode_binary(), appearance := 0..16#FFFF}.

-doc "The advertising data and the scan response data for the UUIDs, the name and the appearance.".
-spec data(input()) -> #{advertising_data := binary(), scan_response_data := binary()}.
data(#{uuids := Uuids, name := Name, appearance := Appearance}) ->
    #{advertising_data => advertising(Uuids), scan_response_data => scan_response(Name, Appearance)}.

advertising(Uuids) ->
    Short = << <<Uuid:16/little>> || Uuid <- Uuids, Uuid =< 16#FFFF >>,
    Long = << <<Uuid:128/little>> || Uuid <- Uuids, Uuid > 16#FFFF >>,
    Data = <<(ad(?ERX_BT_AD_TYPE_FLAGS, <<?ERX_BT_AD_FLAGS_GENERAL_NO_BREDR>>))/binary,
             (list(?ERX_BT_AD_TYPE_UUID16_COMPLETE, Short))/binary,
             (list(?ERX_BT_AD_TYPE_UUID128_COMPLETE, Long))/binary>>,
    case byte_size(Data) =< ?ERX_HCI_ADVERTISING_DATA_MAX of
        true -> Data;
        false -> error(badarg, [Uuids])
    end.

list(_Type, <<>>) -> <<>>;
list(Type, Members) -> ad(Type, Members).

%% The name whole when it fits, else its longest prefix of whole characters; then the
%% appearance when the octets left hold it.
scan_response(Name, Appearance) ->
    NameData = case byte_size(Name) + 2 =< ?ERX_HCI_ADVERTISING_DATA_MAX of
                   true -> ad(?ERX_BT_AD_TYPE_NAME_COMPLETE, Name);
                   false -> ad(?ERX_BT_AD_TYPE_NAME_SHORTENED, prefix(Name, ?ERX_HCI_ADVERTISING_DATA_MAX - 2))
               end,
    AppearanceData = ad(?ERX_BT_AD_TYPE_APPEARANCE, <<Appearance:16/little>>),
    case byte_size(NameData) + byte_size(AppearanceData) =< ?ERX_HCI_ADVERTISING_DATA_MAX of
        true -> <<NameData/binary, AppearanceData/binary>>;
        false -> NameData
    end.

%% The longest prefix of Name in at most Max octets that ends at a character boundary,
%% which is at most three octets shorter.
prefix(Name, Max) ->
    Part = binary:part(Name, 0, Max),
    case unicode:characters_to_binary(Part) of
        Part -> Part;
        _Cut -> prefix(Name, Max - 1)
    end.

ad(Type, Data) -> <<(byte_size(Data) + 1), Type, Data/binary>>.
