%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The boot medium's partition table, parsed and admitted (docs/design-storage.md, "The
%% boot medium's table"): the block driver's pure core for its partition process,
%% erx_blk_service, which reads the five sectors records/0 names and hands them here.
%%
%% The table is the master boot record and exactly four extended boot records, one before
%% each logical partition (system A, system B, the vault's and the data partition's), at
%% sectors the medium layout of the ABI file fixes (abi/medium.txt, through erx_abi.hrl).
%% admit/2 builds the table the layout prescribes and compares the medium's five records
%% with it entry for entry and field for field: status, type, start and length. One value
%% is the medium's to choose, the data partition's length, read from the data partition's
%% record: it must be at least the layout's minimum and end within the medium, and the
%% extended partition's length and the vault record's link length follow from it. No
%% chain is followed: the extended boot records are read where the layout puts them,
%% whatever their link entries say, a link entry that names anything else is refused, and
%% the data partition's record, which names no next record, refuses a fifth. The
%% cylinder-head-sector fields, and the bytes before the entries, are not read.
%%
%% Every value comes from a binary match on a sector of exactly the format's size, so a
%% short, long or non-binary record is refused with a reason, never a crash; the reasons
%% are a closed set of atoms and the medium's capacity, an integer the device reported.
%% Values are compared as Erlang integers, which do not overflow, so a computed length no
%% 32-bit field can hold is a difference, not a wrap. place/3 is a window's check of a
%% request against its sectors.
%%
%% The windows' roles are abi/manifest.txt's mf_window_role names (role/1), but the
%% record partition's, record, which holds both the boot-selection record and the reset
%% count. admit/2 names a window on each partition of the layout but the two system
%% partitions: the slot writer's windows on those wait for its grant, so nothing in the
%% driver's domain writes a system partition. booted/1 names the one window the boot value
%% decides (PW1 of docs/design-storage.md; docs/design-stopgap.md, "The booted slot"):
%% system, read-only, on the system partition of the slot that `-erx_record boot VALUE
%% SLOT` names, for the holder the domain library gave the slot's `-erx_record
%% system_image` record, and none on a boot that names no slot, an unknown boot, on boot
%% words it refuses, or for a holder given no record or one the record's reader refuses;
%% and record_volume, read-only, on the whole record partition, for the holder whose
%% record names it, whatever the boot words name (docs/design-storage.md, "Removable
%% media: FAT").
%%
%% read_only/1 is which roles take no write.

-module(erx_blk_table).

-export([records/0, minimum_sectors/0, check_capacity/1, admit/2, place/3]).
-export([booted/1, system_partition/1, read_only/1]).
-export_type([role/0, window/0, slot/0, record_name/0, reason/0]).

-include("generated/erx_abi.hrl").

%% A name of abi/manifest.txt's mf_window_role (role/1), the record partition's record,
%% or {image, Name}, a window on one of the booted slot's EROFS images (erx_blk_image).
-type role() :: record | erx_abi_enums:mf_window_role() | {image, binary()}.
%% A slot as the boot value's words name it.
-type slot() :: a | b.
%% A window: its role, its first sector on the medium and its length in sectors.
-type window() :: {role(), non_neg_integer(), pos_integer()}.
-type record_name() :: mbr | system_a_ebr | system_b_ebr | vault_ebr | data_ebr.
-type field() :: status | type | start | sectors.
-type reason() :: {capacity, term()}
                | {record_name(), size | signature}
                | {record_name(), 1..4, field()}.
%% One entry as the table holds it: status, type, start and length.
-type entry() :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}.
%% A logical partition of the extended partition: its record's name and sector, then the
%% partition's type, start and length.
-type logical() :: #{record := record_name(), ebr := non_neg_integer(), type := non_neg_integer(),
                     start := non_neg_integer(), sectors := pos_integer()}.

%% The five records of the table and their sectors, in the order admit/2 takes them. A
%% record's sector does not depend on the data partition's length, so any length serves.
-spec records() -> [{record_name(), non_neg_integer()}].
records() ->
    [{mbr, 0} | [{Name, Ebr} || #{record := Name, ebr := Ebr} <- logicals(?ERX_MEDIUM_DATA_SECTORS_MIN)]].

%% The fewest sectors a medium laid out by the layout has: through the data partition's
%% minimum length.
-spec minimum_sectors() -> pos_integer().
minimum_sectors() -> ?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN.

%% ok when a medium of Capacity sectors can hold the layout, so its records can be read.
-spec check_capacity(term()) -> ok | {error, reason()}.
check_capacity(Capacity) when is_integer(Capacity), Capacity >= ?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN ->
    ok;
check_capacity(Capacity) ->
    {error, {capacity, Capacity}}.

%% The windows of a medium of Capacity sectors whose records/0 sectors hold Sectors, one
%% each in records/0's order, or the first way the table differs from the layout. What
%% each sector holds is the medium's, refused with a reason; that Sectors has one term
%% per record is the caller's precondition, and another count is a crash.
-spec admit(term(), [term()]) -> {ok, [window()]} | {error, reason()}.
admit(Capacity, Sectors) when is_list(Sectors) ->
    Names = [Name || {Name, _Sector} <- records()],
    maybe
        ok ?= check_capacity(Capacity),
        {ok, Read} ?= read_entries(lists:zip(Names, Sectors), []),
        {ok, DataSectors} ?= data_sectors(Capacity, proplists:get_value(data_ebr, Read)),
        ok ?= compare(Read, expected(DataSectors)),
        {ok, [{record, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
              {role(?ERX_MF_WINDOW_ROLE_BOOT_A), ?ERX_MEDIUM_BOOT_A_START, ?ERX_MEDIUM_BOOT_SECTORS},
              {role(?ERX_MF_WINDOW_ROLE_BOOT_B), ?ERX_MEDIUM_BOOT_B_START, ?ERX_MEDIUM_BOOT_SECTORS},
              {role(?ERX_MF_WINDOW_ROLE_VAULT), ?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
              {role(?ERX_MF_WINDOW_ROLE_DATA), ?ERX_MEDIUM_DATA_START, DataSectors}]}
    end.

%% The booted slot and the windows it decides, from Arguments, what
%% erx_device_record:records/0 returns: the slot and its system window, or none and no
%% window on a boot that names no slot; on boot words boot_slot/1 refuses, none and no
%% window too, with the refusal for the caller's log. The system window is the holder's
%% of the manifest's system window row, the one domain the domain library gives a
%% system_image record: a holder whose record erx_device_record:system_image/1 does not
%% take gets no system window, the refusal is returned for the log, and the slot is kept
%% for the images erx_blk_image places on it. The same holder's record names the
%% record_volume window when the domain library gave the domain the manifest's
%% record_volume window too (erx_device_record:record_volume/1); that window lies on the
%% record partition, which belongs to neither slot, so it follows the record alone.
-spec booted(term()) -> {slot() | none, [window()],
                         ok | {error, bad_boot | {bad_device_record, string()}}}.
booted(Arguments) ->
    {Slot, System, Status} = case boot_slot(Arguments) of
                                 {ok, none} -> {none, [], ok};
                                 {ok, Booted} -> system_window(Booted, erx_device_record:system_image(Arguments));
                                 Refused -> {none, [], Refused}
                             end,
    {Slot, System ++ record_volume_window(erx_device_record:record_volume(Arguments)), Status}.

record_volume_window(true) ->
    [{role(?ERX_MF_WINDOW_ROLE_RECORD_VOLUME), ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS}];
record_volume_window(false) ->
    [].

system_window(Slot, {ok, _Layout}) -> {Slot, system_window(Slot), ok};
system_window(Slot, {error, _} = Refused) -> {Slot, [], Refused}.

%% The slot of `-erx_record boot VALUE SLOT` in Arguments, by the names of
%% include/erx/core/boot_pair.h: none when there is no such word list or its value is
%% unknown; bad_boot for more than one, for words after the slot, or for a value and slot
%% that are not a pair boot_pair.h accepts.
boot_slot(Arguments) when is_list(Arguments) ->
    case [Words || ["boot" | Words] <- Arguments] of
        [] -> {ok, none};
        [["unknown", "none"]] -> {ok, none};
        [[Value, "a"]] when Value =:= "normal"; Value =:= "trial" -> {ok, a};
        [[Value, "b"]] when Value =:= "normal"; Value =:= "trial" -> {ok, b};
        _ -> {error, bad_boot}
    end;
boot_slot(_Arguments) ->
    {error, bad_boot}.

%% The system window of a boot that booted Slot, on that slot's system partition.
system_window(Slot) ->
    {Start, Sectors} = system_partition(Slot),
    [{role(?ERX_MF_WINDOW_ROLE_SYSTEM), Start, Sectors}].

%% The first sector and the length of Slot's system partition.
-spec system_partition(slot()) -> {non_neg_integer(), pos_integer()}.
system_partition(a) -> {?ERX_MEDIUM_SYSTEM_A_START, ?ERX_MEDIUM_SYSTEM_SECTORS};
system_partition(b) -> {?ERX_MEDIUM_SYSTEM_B_START, ?ERX_MEDIUM_SYSTEM_SECTORS}.

%% Whether a window of Role takes no write: a role abi/manifest.txt does not mark
%% writable. An image window is a verified_image window, and the record window, which
%% holds the boot_selection and reset_count records, is read-only if either of them is.
-spec read_only(role()) -> boolean().
read_only({image, _Name}) -> read_only(verified_image);
read_only(record) -> read_only(boot_selection) orelse read_only(reset_count);
read_only(Role) -> not erx_abi_enums:mf_window_role_writable(Role).

%% The medium's first sector of a request for Count sectors from Sector of Window: einval
%% for a request that names no sectors, erange for one that leaves the window.
-spec place(window(), term(), term()) -> {ok, non_neg_integer()} | {error, einval | erange}.
place({_Role, Start, Sectors}, Sector, Count)
  when is_integer(Sector), is_integer(Count), Sector >= 0, Count >= 1 ->
    case Sector + Count =< Sectors of
        true -> {ok, Start + Sector};
        false -> {error, erange}
    end;
place(_Window, _Sector, _Count) ->
    {error, einval}.

%% The name abi/manifest.txt gives the window role of value Value.
role(Value) ->
    {Name, Value} = lists:keyfind(Value, 2, ?ERX_MF_WINDOW_ROLE_MEMBERS),
    Name.

%% Each named record's four entries, or the first record that is not a record.
read_entries([], Read) ->
    {ok, lists:reverse(Read)};
read_entries([{Name, Sector} | Rest], Read) ->
    case entries(Name, Sector) of
        {ok, Entries} -> read_entries(Rest, [{Name, Entries} | Read]);
        Error -> Error
    end.

%% The four entries of a record of exactly one sector that ends in the signature.
entries(Name, Sector) when is_binary(Sector), byte_size(Sector) =:= ?ERX_MBR_SECTOR_SIZE ->
    <<_:?ERX_MBR_ENTRIES_OFFSET/binary, Entries:(?ERX_MBR_ENTRIES * ?ERX_MBR_ENTRY_SIZE)/binary, _/binary>> = Sector,
    <<_:?ERX_MBR_SIGNATURE_OFFSET/binary, Signature:16/little, _/binary>> = Sector,
    case Signature of
        ?ERX_MBR_SIGNATURE -> {ok, [entry(Entry) || <<Entry:?ERX_MBR_ENTRY_SIZE/binary>> <= Entries]};
        _ -> {error, {Name, signature}}
    end;
entries(Name, _Sector) ->
    {error, {Name, size}}.

entry(Entry) ->
    <<_:?ERX_MBR_ENTRY_OFF_STATUS/binary, Status:8, _/binary>> = Entry,
    <<_:?ERX_MBR_ENTRY_OFF_TYPE/binary, Type:8, _/binary>> = Entry,
    <<_:?ERX_MBR_ENTRY_OFF_LBA_START/binary, Start:32/little, _/binary>> = Entry,
    <<_:?ERX_MBR_ENTRY_OFF_LBA_SECTORS/binary, Sectors:32/little, _/binary>> = Entry,
    {Status, Type, Start, Sectors}.

%% The data partition's length, the one value the medium chooses: from the layout's
%% minimum to the medium's end. Its record's other fields are compared with the rest.
data_sectors(Capacity, [{_Status, _Type, _Start, Sectors} | _]) ->
    case Sectors >= ?ERX_MEDIUM_DATA_SECTORS_MIN andalso ?ERX_MEDIUM_DATA_START + Sectors =< Capacity of
        true -> {ok, Sectors};
        false -> {error, {data_ebr, 1, sectors}}
    end.

%% The extended partition's logical partitions in medium order, for a data partition of
%% DataSectors sectors: each its record's name and sector, then the partition's type, start
%% and length. The layout's one list of them, from which records/0 and expected/1 both read.
-spec logicals(pos_integer()) -> [logical()].
logicals(DataSectors) ->
    [#{record => system_a_ebr, ebr => ?ERX_MEDIUM_SYSTEM_A_EBR, type => ?ERX_MEDIUM_SYSTEM_TYPE,
       start => ?ERX_MEDIUM_SYSTEM_A_START, sectors => ?ERX_MEDIUM_SYSTEM_SECTORS},
     #{record => system_b_ebr, ebr => ?ERX_MEDIUM_SYSTEM_B_EBR, type => ?ERX_MEDIUM_SYSTEM_TYPE,
       start => ?ERX_MEDIUM_SYSTEM_B_START, sectors => ?ERX_MEDIUM_SYSTEM_SECTORS},
     #{record => vault_ebr, ebr => ?ERX_MEDIUM_VAULT_EBR, type => ?ERX_MEDIUM_VAULT_TYPE,
       start => ?ERX_MEDIUM_VAULT_START, sectors => ?ERX_MEDIUM_VAULT_SECTORS},
     #{record => data_ebr, ebr => ?ERX_MEDIUM_DATA_EBR, type => ?ERX_MEDIUM_DATA_TYPE,
       start => ?ERX_MEDIUM_DATA_START, sectors => DataSectors}].

%% The table the layout prescribes for a data partition of DataSectors sectors, record by
%% record in records/0's order. The extended partition starts at the first logical
%% partition's record and ends with the data partition. An extended boot record's first
%% entry starts relative to the record's own sector, and its second is the link to the
%% next logical partition's record (link_to/2).
-spec expected(pos_integer()) -> [{record_name(), [entry()]}].
expected(DataSectors) ->
    Logicals = logicals(DataSectors),
    #{ebr := Extended} = hd(Logicals),
    DataEnd = ?ERX_MEDIUM_DATA_START + DataSectors,
    Nexts = tl(Logicals) ++ [last],
    [{mbr, [used(?ERX_MEDIUM_RECORD_TYPE, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS),
            used(?ERX_MEDIUM_BOOT_TYPE, ?ERX_MEDIUM_BOOT_A_START, ?ERX_MEDIUM_BOOT_SECTORS),
            used(?ERX_MEDIUM_BOOT_TYPE, ?ERX_MEDIUM_BOOT_B_START, ?ERX_MEDIUM_BOOT_SECTORS),
            used(?ERX_MEDIUM_EXTENDED_TYPE, Extended, DataEnd - Extended)]}
     | [{Name, [used(Type, Start - Ebr, Sectors), link_to(Next, Extended), unused(), unused()]}
        || {#{record := Name, ebr := Ebr, type := Type, start := Start, sectors := Sectors}, Next}
               <- lists:zip(Logicals, Nexts)]].

%% A record's link entry when the logical partition after its own is Next: from the
%% extended partition's start, spanning Next's record and Next; the last record has none.
link_to(last, _Extended) ->
    unused();
link_to(#{ebr := Ebr, start := Start, sectors := Sectors}, Extended) ->
    used(?ERX_MEDIUM_LINK_TYPE, Ebr - Extended, Start + Sectors - Ebr).

used(Type, Start, Sectors) -> {?ERX_MBR_STATUS_INACTIVE, Type, Start, Sectors}.

unused() -> {?ERX_MBR_STATUS_INACTIVE, ?ERX_MBR_TYPE_EMPTY, 0, 0}.

%% ok when every entry of every record equals the layout's, or the first record, entry and
%% field that do not. The two lists name the same records in the same order; differences/2
%% matches each pair by name, so a pairing that drifted fails loudly instead of skipping.
compare(Read, Expected) ->
    case lists:append(lists:zipwith(fun differences/2, Read, Expected)) of
        [] -> ok;
        [First | _] -> {error, First}
    end.

differences({Name, Entries}, {Name, Wanted}) ->
    [{Name, Index, field(Entry, Want)}
     || {Index, Entry, Want} <- lists:zip3(lists:seq(1, length(Wanted)), Entries, Wanted), Entry =/= Want].

field({Status, _, _, _}, {Want, _, _, _}) when Status =/= Want -> status;
field({_, Type, _, _}, {_, Want, _, _}) when Type =/= Want -> type;
field({_, _, Start, _}, {_, _, Want, _}) when Start =/= Want -> start;
field(_Entry, _Want) -> sectors.
