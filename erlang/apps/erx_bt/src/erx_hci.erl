%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hci).
-moduledoc """
The HCI codec of the controller process (docs/design-bluetooth.md, "Commands and data
credits"): the commands the host sends and the events it decodes, from the Bluetooth
Core Specification 6.3, Vol 4 Part E, whose codes abi/formats/bluetooth.txt holds.

`command/1` gives a command's opcode and parameters (section 7). `event/2` decodes an
event packet's code and parameters into a term, and `return/2` a Command Complete's
return parameters for the command they answer. Every event controller input reaches
is checked whole against its section's layout, so a length that does not match is
`malformed` rather than read past; an event or LE subevent this host does not use is
`{unknown, Code}`, which the caller counts and drops. Nothing here makes an atom.
""".

-include("generated/erx_abi.hrl").

-export([command/1, opcode/1, event/2, return/2]).
-export_type([command/0, command_name/0, event/0, return/0]).

-type handle() :: 0..16#FFF.
-type address() :: <<_:48>>.

-doc "The commands the host sends, by the names of abi/formats/bluetooth.txt's OCF enums.".
-type command() :: reset | read_local_version | read_local_commands | read_buffer_size | read_bd_addr
                 | le_read_buffer_size | le_read_features
                 | {set_event_mask, 0..16#FFFFFFFFFFFFFFFF}
                 | {le_set_event_mask, 0..16#FFFFFFFFFFFFFFFF}
                 | {host_buffer_size, AclLength :: 0..16#FFFF, AclPackets :: 0..16#FFFF}
                 | {le_set_random_address, address()}
                 | {le_set_advertising_parameters, Interval :: 16#20..16#4000}
                 | {le_set_advertising_data, binary()}
                 | {le_set_scan_response_data, binary()}
                 | {le_set_advertising_enable, boolean()}
                 | {disconnect, handle(), Reason :: byte()}
                 | {vendor, Opcode :: 0..16#FFFF, binary()}.
-type command_name() :: atom().

-type event() :: {command_complete, Allowed :: byte(), Opcode :: 0..16#FFFF, Return :: binary()}
               | {command_status, Status :: byte(), Allowed :: byte(), Opcode :: 0..16#FFFF}
               | {disconnection_complete, Status :: byte(), handle(), Reason :: byte()}
               | {encryption_change, Status :: byte(), handle(), Enabled :: byte()}
               | {encryption_key_refresh_complete, Status :: byte(), handle()}
               | {hardware_error, byte()}
               | {number_of_completed_packets, [{handle(), 0..16#FFFF}]}
               | {le_connection_complete, Status :: byte(), handle(), #{atom() => term()}}
               | {le_connection_update_complete, Status :: byte(), handle()}
               | {le_long_term_key_request, handle(), Random :: <<_:64>>, Ediv :: 0..16#FFFF}
               | {unknown, byte() | {le_meta, byte()}}
               | malformed.

-type return() :: {ok, term()} | {failed, Status :: 1..255} | malformed.

-doc "The opcode and parameters of a command.".
-spec command(command()) -> {0..16#FFFF, binary()}.
command({vendor, Opcode, Parameters}) -> {Opcode, Parameters};
command(Command) when is_atom(Command) -> {opcode(Command), <<>>};
command({Name, _} = Command) -> {opcode(Name), parameters(Command)};
command({Name, _, _} = Command) -> {opcode(Name), parameters(Command)}.

parameters({set_event_mask, Mask}) -> <<Mask:64/little>>;
parameters({le_set_event_mask, Mask}) -> <<Mask:64/little>>;
%% Host Buffer Size (7.3.39): the ACL length and count; no synchronous packets.
parameters({host_buffer_size, Length, Packets}) -> <<Length:16/little, 0, Packets:16/little, 0:16>>;
parameters({le_set_random_address, Address}) -> address(Address);
%% LE Set Advertising Parameters (7.8.5): the interval as minimum and maximum, then the
%% type, the own and the peer address types, a peer address of zeros (unused by ADV_IND),
%% the channel map and filter policy 0, which takes every scan and connection.
parameters({le_set_advertising_parameters, Interval}) ->
    <<Interval:16/little, Interval:16/little, ?ERX_HCI_ADVERTISING_TYPE_IND, ?ERX_HCI_OWN_ADDRESS_RANDOM,
      0, 0:48, ?ERX_HCI_ADVERTISING_CHANNELS_ALL, 0>>;
parameters({le_set_advertising_data, Data}) -> advertising_data(Data);
parameters({le_set_scan_response_data, Data}) -> advertising_data(Data);
parameters({le_set_advertising_enable, Enable}) -> <<(enable(Enable))>>;
parameters({disconnect, Handle, Reason}) when Handle =< ?ERX_HCI_HANDLE_MAX -> <<Handle:16/little, Reason>>.

%% A BD_ADDR is sent and received least significant octet first (Vol 4 Part E, 5.2);
%% the host keeps it most significant first, as it is written.
address(<<_:48>> = Address) -> reverse(Address).

reverse(Bytes) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).

%% Advertising data: its length, then 31 octets, the unused ones zero (7.8.7, 7.8.8).
advertising_data(Data) when byte_size(Data) =< ?ERX_HCI_ADVERTISING_DATA_MAX ->
    Pad = (?ERX_HCI_ADVERTISING_DATA_MAX - byte_size(Data)) * 8,
    <<(byte_size(Data)), Data/binary, 0:Pad>>.

enable(true) -> 1;
enable(false) -> 0.

-doc "The opcode of a command name: its OGF in the upper 6 bits and its OCF in the lower 10 (Part E, section 5.4.1).".
-spec opcode(command_name()) -> 0..16#FFFF.
opcode(Name) ->
    {Ogf, Ocf} = group(Name),
    (Ogf bsl ?ERX_HCI_OCF_BITS) bor Ocf.

group(disconnect) -> {?ERX_HCI_OGF_LINK_CONTROL, ?ERX_HCI_LINK_CONTROL_OCF_DISCONNECT};
group(set_event_mask) -> {?ERX_HCI_OGF_CONTROLLER, ?ERX_HCI_CONTROLLER_OCF_SET_EVENT_MASK};
group(reset) -> {?ERX_HCI_OGF_CONTROLLER, ?ERX_HCI_CONTROLLER_OCF_RESET};
group(host_buffer_size) -> {?ERX_HCI_OGF_CONTROLLER, ?ERX_HCI_CONTROLLER_OCF_HOST_BUFFER_SIZE};
group(read_local_version) -> {?ERX_HCI_OGF_INFORMATIONAL, ?ERX_HCI_INFORMATIONAL_OCF_READ_LOCAL_VERSION};
group(read_local_commands) -> {?ERX_HCI_OGF_INFORMATIONAL, ?ERX_HCI_INFORMATIONAL_OCF_READ_LOCAL_COMMANDS};
group(read_buffer_size) -> {?ERX_HCI_OGF_INFORMATIONAL, ?ERX_HCI_INFORMATIONAL_OCF_READ_BUFFER_SIZE};
group(read_bd_addr) -> {?ERX_HCI_OGF_INFORMATIONAL, ?ERX_HCI_INFORMATIONAL_OCF_READ_BD_ADDR};
group(le_set_event_mask) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_SET_EVENT_MASK};
group(le_read_buffer_size) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_READ_BUFFER_SIZE};
group(le_read_features) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_READ_FEATURES};
group(le_set_random_address) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_SET_RANDOM_ADDRESS};
group(le_set_advertising_parameters) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_SET_ADVERTISING_PARAMETERS};
group(le_set_advertising_data) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_SET_ADVERTISING_DATA};
group(le_set_scan_response_data) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_SET_SCAN_RESPONSE_DATA};
group(le_set_advertising_enable) -> {?ERX_HCI_OGF_LE, ?ERX_HCI_LE_OCF_LE_SET_ADVERTISING_ENABLE}.

-doc "An event packet's code and parameters as a term (Part E, section 7.7).".
-spec event(byte(), binary()) -> event().
event(Code, Parameters) ->
    try decode(Code, Parameters) catch throw:malformed -> malformed end.

decode(?ERX_HCI_EVENT_COMMAND_COMPLETE, <<Allowed, Opcode:16/little, Return/binary>>) ->
    {command_complete, Allowed, Opcode, Return};
decode(?ERX_HCI_EVENT_COMMAND_STATUS, <<Status, Allowed, Opcode:16/little>>) ->
    {command_status, Status, Allowed, Opcode};
decode(?ERX_HCI_EVENT_DISCONNECTION_COMPLETE, <<Status, Handle:16/little, Reason>>) ->
    {disconnection_complete, Status, handle(Handle), Reason};
decode(?ERX_HCI_EVENT_ENCRYPTION_CHANGE, <<Status, Handle:16/little, Enabled>>) ->
    {encryption_change, Status, handle(Handle), Enabled};
decode(?ERX_HCI_EVENT_ENCRYPTION_KEY_REFRESH_COMPLETE, <<Status, Handle:16/little>>) ->
    {encryption_key_refresh_complete, Status, handle(Handle)};
decode(?ERX_HCI_EVENT_HARDWARE_ERROR, <<Code>>) ->
    {hardware_error, Code};
%% Num_Handles, then each Handle[i] beside its Num_Completed_Packets[i] (7.7.19; the
%% order of arrayed parameters is section 5.2's).
decode(?ERX_HCI_EVENT_NUMBER_OF_COMPLETED_PACKETS, <<Count, Pairs/binary>>) when byte_size(Pairs) =:= Count * 4 ->
    {number_of_completed_packets, [{handle(Handle), Packets} || <<Handle:16/little, Packets:16/little>> <= Pairs]};
decode(?ERX_HCI_EVENT_LE_META, <<Subevent, Parameters/binary>>) ->
    le_event(Subevent, Parameters);
decode(Code, _) when Code =:= ?ERX_HCI_EVENT_COMMAND_COMPLETE; Code =:= ?ERX_HCI_EVENT_COMMAND_STATUS;
                    Code =:= ?ERX_HCI_EVENT_DISCONNECTION_COMPLETE; Code =:= ?ERX_HCI_EVENT_ENCRYPTION_CHANGE;
                    Code =:= ?ERX_HCI_EVENT_ENCRYPTION_KEY_REFRESH_COMPLETE; Code =:= ?ERX_HCI_EVENT_HARDWARE_ERROR;
                    Code =:= ?ERX_HCI_EVENT_NUMBER_OF_COMPLETED_PACKETS; Code =:= ?ERX_HCI_EVENT_LE_META ->
    malformed;
decode(Code, _) ->
    {unknown, Code}.

%% LE Connection Complete (7.7.65.1), LE Connection Update Complete (7.7.65.3) and LE
%% Long Term Key Request (7.7.65.5), each after its subevent code.
le_event(?ERX_HCI_LE_SUBEVENT_CONNECTION_COMPLETE,
         <<Status, Handle:16/little, Role, PeerType, Peer:6/binary, Interval:16/little, Latency:16/little,
           Timeout:16/little, _ClockAccuracy>>) ->
    {le_connection_complete, Status, handle(Handle),
     #{role => Role, peer_type => PeerType, peer => reverse(Peer), interval => Interval, latency => Latency,
       timeout => Timeout}};
le_event(?ERX_HCI_LE_SUBEVENT_CONNECTION_UPDATE_COMPLETE,
         <<Status, Handle:16/little, _Interval:16, _Latency:16, _Timeout:16>>) ->
    {le_connection_update_complete, Status, handle(Handle)};
le_event(?ERX_HCI_LE_SUBEVENT_LONG_TERM_KEY_REQUEST, <<Handle:16/little, Random:8/binary, Ediv:16/little>>) ->
    {le_long_term_key_request, handle(Handle), Random, Ediv};
le_event(Subevent, _) when Subevent =:= ?ERX_HCI_LE_SUBEVENT_CONNECTION_COMPLETE;
                           Subevent =:= ?ERX_HCI_LE_SUBEVENT_CONNECTION_UPDATE_COMPLETE;
                           Subevent =:= ?ERX_HCI_LE_SUBEVENT_LONG_TERM_KEY_REQUEST ->
    malformed;
le_event(Subevent, _) ->
    {unknown, {le_meta, Subevent}}.

%% A Connection_Handle's 12 meaningful bits, from 0x000 to 0xEFF (5.4.2); a reserved
%% handle makes the event malformed.
handle(Word) when Word band 16#FFF =< ?ERX_HCI_HANDLE_MAX -> Word band 16#FFF;
handle(_Word) -> throw(malformed).

-doc """
A Command Complete's return parameters for the command named, which begin with its
status: `{failed, Status}` for a status other than success, whatever follows it, and
for success the values the bring-up reads, each layout checked whole.
""".
-spec return(command_name(), binary()) -> return().
return(_Name, <<Status, _/binary>>) when Status =/= ?ERX_HCI_STATUS_SUCCESS ->
    {failed, Status};
%% Read Local Version Information (7.4.1).
return(read_local_version, <<_, HciVersion, HciSubversion:16/little, LmpVersion, Company:16/little,
                             LmpSubversion:16/little>>) ->
    {ok, #{hci_version => HciVersion, hci_subversion => HciSubversion, lmp_version => LmpVersion,
           company => Company, lmp_subversion => LmpSubversion}};
%% Read Local Supported Commands [v1] (7.4.2) and LE Read Local Supported Features
%% Page 0 (7.8.3): bit maps, kept as they are.
return(read_local_commands, <<_, Commands:64/binary>>) -> {ok, Commands};
return(le_read_features, <<_, Features:8/binary>>) -> {ok, Features};
return(read_bd_addr, <<_, Address:6/binary>>) -> {ok, reverse(Address)};
%% LE Read Buffer Size [v1] (7.8.2) and Read Buffer Size (7.4.5): the ACL length and
%% count from host to controller.
return(le_read_buffer_size, <<_, Length:16/little, Packets>>) -> {ok, {Length, Packets}};
return(read_buffer_size, <<_, Length:16/little, _SyncLength, Packets:16/little, _SyncPackets:16>>) ->
    {ok, {Length, Packets}};
%% The commands that return their status alone.
return(Name, <<_>>) when Name =:= reset; Name =:= set_event_mask; Name =:= host_buffer_size;
                         Name =:= le_set_event_mask; Name =:= le_set_random_address;
                         Name =:= le_set_advertising_parameters; Name =:= le_set_advertising_data;
                         Name =:= le_set_scan_response_data; Name =:= le_set_advertising_enable;
                         Name =:= disconnect; Name =:= vendor ->
    {ok, done};
return(_Name, _) -> malformed.
