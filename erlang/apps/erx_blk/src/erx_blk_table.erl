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

-module(erx_blk_table).

-export([records/0, minimum_sectors/0, check_capacity/1, admit/2, place/3]).
-export_type([role/0, window/0, record_name/0, reason/0]).

-include("generated/erx_abi.hrl").

%% {image, Name} is a window on one of the booted slot's EROFS images (erx_blk_image).
%% slot_a and slot_b are the two slots' boot partitions.
-type role() :: record | slot_a | slot_b | vault | data | {image, binary()}.
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
              {slot_a, ?ERX_MEDIUM_BOOT_A_START, ?ERX_MEDIUM_BOOT_SECTORS},
              {slot_b, ?ERX_MEDIUM_BOOT_B_START, ?ERX_MEDIUM_BOOT_SECTORS},
              {vault, ?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
              {data, ?ERX_MEDIUM_DATA_START, DataSectors}]}
    end.

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
