%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_read).
-moduledoc """
The pure read core of the FAT format (docs/design-storage.md, "Removable media:
FAT" and "The record volume's one reader"): root_file/3 finds one file of the
boot medium's record volume by its long name in the root directory and answers
exactly the bytes its directory entry's size gives. It reads the volume one
sector at a time through the function it is handed, so it holds no device and
no state, and the medium's bytes are untrusted input.

* **The volume.** The boot sector is admitted only as abi/medium.txt lays the
  record partition out: 512-byte sectors and one-sector clusters, a FAT16 by
  its count of clusters, every region inside the partition, the reserved area
  covering the reset count's sector (`medium_record_count_start`), so neither a
  FAT nor the root directory holds it, and the data area starting at the
  record's sector (`medium_record_select_start`). Anything else is
  `not_its_volume`.
* **The lookup.** The root directory is read entry by entry up to its end
  marker or its last entry. A long name counts only when its entries run in
  order from the last to the first and each carries the checksum of the short
  entry that follows them; it is compared with the name asked for after ASCII
  letters are mapped to upper case. Deleted entries, directories and volume
  labels are never the file. No such file is `not_found`.
* **The read.** A size past MaxBytes is `too_long` before any cluster is read.
  Exactly as many clusters as the size needs are read, each a cluster of the
  data area and none seen before in the chain; the chain past them is not
  read. A link out of the data area, a cluster seen twice and an end of chain
  before the size's clusters are `does_not_read`. So whatever the FAT holds,
  the read is the boot sector,
  at most 4096 root-directory sectors (RootEntries is 16 bits), and at most
  MaxBytes / 512 data sectors and as many FAT sectors.

A sector the function does not answer with 512 bytes is `read_failed`, which is
about the medium's reading, not about the file. Each finding leaves the reader
through one throw, `{erx_fat_read, Finding}`, caught in root_file/3; anything
else the read function raises or throws propagates.
""".

-include("generated/erx_abi.hrl").

-export([root_file/3, boot_sector/1]).
-export_type([finding/0, read_sector/0, fat_type/0]).

-define(SECTOR, 512).
-define(ENTRY, 32).
-define(ENTRIES_PER_SECTOR, (?SECTOR div ?ENTRY)).
%% A FAT16 has at least 4085 and fewer than 65525 clusters (the FAT specification,
%% version 1.03, section 3.5).
-define(FAT16_MIN, 4085).
-define(FAT32_MIN, 65525).
%% Directory entry markers and attributes (section 6).
-define(END_OF_DIRECTORY, 16#00).
-define(DELETED, 16#e5).
-define(VOLUME_ID, 16#08).
-define(DIRECTORY, 16#10).
-define(LONG_NAME, 16#0f).
-define(LONG_NAME_MASK, 16#3f).
%% A long-name entry's order number, below its last-entry flag (section 7).
-define(ORDER_MASK, 16#3f).
-define(LAST_LONG_ENTRY, 16#40).

-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
-type finding() :: not_its_volume | not_found | too_long | does_not_read | read_failed.

%% The volume as the boot sector lays it out, in sectors from the partition's start.
-record(volume, {read :: read_sector(),
                 fat :: pos_integer(),
                 root :: pos_integer(),
                 root_entries :: pos_integer(),
                 clusters :: pos_integer()}).

-doc """
The bytes of the root directory's file named Name, an ASCII long name compared
without regard to the case of its letters, read through Read; a file past MaxBytes
is `too_long`. Each refusal is a `t:finding/0`.
""".
-spec root_file(read_sector(), binary(), non_neg_integer()) -> {ok, binary()} | {error, finding()}.
root_file(Read, Name, MaxBytes) ->
    try
        Volume = volume(Read),
        {First, Size} = lookup(Volume, upper(Name)),
        Size =< MaxBytes orelse fail(too_long),
        {ok, contents(Volume, First, Size)}
    catch
        throw:{?MODULE, Finding} -> {error, Finding}
    end.

fail(Finding) -> throw({?MODULE, Finding}).

-type fat_type() :: 12 | 16 | 32 | none.

-doc """
Whether a volume whose first sector is Sector holds FAT, by fstyp's test
(usr.sbin/fstyp/msdosfs.c:48-115 at FreeBSD 95719d8a895b): the boot sector's
`0x55 0xAA` signature, or the Raspberry Pi Pico bootloader's zero signature behind
its jump bytes, then a non-zero 16-bit FAT size with `FAT` at the FAT12 and FAT16
type field, or a zero one and a non-zero 32-bit FAT size with `FAT` at FAT32's. A
FAT volume's type follows from its count of clusters alone (section 3.5), and is
`none` when its BIOS parameter block gives no count: a zero sector or cluster size,
or a data area that starts at or past the volume's end. The drives' probe and the
FAT server's mount both take the type from here.
""".
-spec boot_sector(<<_:4096>>) -> {fat, fat_type()} | not_fat.
boot_sector(<<Jump:3/binary, _Oem:8/binary, BytesPerSector:16/little, PerCluster, Reserved:16/little, Fats,
              RootEntries:16/little, Total16:16/little, _Media, Fat16:16/little, _:8/binary, Total32:32/little,
              Fat32:32/little, _:14/binary, Type16:3/binary, _:25/binary, Type32:3/binary, _:425/binary,
              Signature:2/binary>>) ->
    Signed = Signature =:= <<16#55, 16#aa>>
        orelse (Signature =:= <<0, 0>> andalso Jump =:= <<16#eb, 16#3c, 16#90>>),
    Named = (Fat16 =/= 0 andalso Type16 =:= <<"FAT">>)
        orelse (Fat16 =:= 0 andalso Fat32 =/= 0 andalso Type32 =:= <<"FAT">>),
    FatSectors = case Fat16 of 0 -> Fat32; _ -> Fat16 end,
    Total = case Total16 of 0 -> Total32; _ -> Total16 end,
    case Signed andalso Named of
        true -> {fat, fat_type(BytesPerSector, PerCluster, Total, Reserved + Fats * FatSectors, RootEntries)};
        false -> not_fat
    end.

%% The type from the count of clusters, the data area starting after Before
%% sectors and the root directory's.
fat_type(BytesPerSector, PerCluster, _Total, _Before, _RootEntries) when BytesPerSector =:= 0; PerCluster =:= 0 ->
    none;
fat_type(BytesPerSector, PerCluster, Total, Before, RootEntries) ->
    DataStart = Before + (RootEntries * ?ENTRY + BytesPerSector - 1) div BytesPerSector,
    case Total > DataStart andalso (Total - DataStart) div PerCluster of
        false -> none;
        Clusters when Clusters < ?FAT16_MIN -> 12;
        Clusters when Clusters < ?FAT32_MIN -> 16;
        _ -> 32
    end.

sector(Read, Index) ->
    case Read(Index) of
        {ok, <<Bytes:?SECTOR/binary>>} -> Bytes;
        _ -> fail(read_failed)
    end.

%% The boot sector's BPB (section 3.1) and its admission: a FAT16 by boot_sector/1,
%% the one place a volume's type is decided, laid out as the record partition.
volume(Read) ->
    case sector(Read, 0) of
        <<_:11/binary, ?SECTOR:16/little, 1, Reserved:16/little, Fats, RootEntries:16/little,
          Total16:16/little, _Media, FatSectors:16/little, _:8/binary, Total32:32/little,
          _:474/binary, 16#55, 16#aa>> = Sector ->
            Total = case Total16 of 0 -> Total32; _ -> Total16 end,
            Root = Reserved + Fats * FatSectors,
            DataStart = Root + (RootEntries * ?ENTRY + ?SECTOR - 1) div ?SECTOR,
            Clusters = Total - DataStart,
            admitted(boot_sector(Sector) =:= {fat, 16}
                     andalso Reserved > ?ERX_MEDIUM_RECORD_COUNT_START andalso Fats >= 1 andalso RootEntries >= 1
                     andalso DataStart =:= ?ERX_MEDIUM_RECORD_SELECT_START
                     andalso Total =< ?ERX_MEDIUM_RECORD_SECTORS
                     andalso FatSectors * ?SECTOR >= (Clusters + 2) * 2),
            #volume{read = Read, fat = Reserved, root = Root, root_entries = RootEntries, clusters = Clusters};
        _ ->
            fail(not_its_volume)
    end.

admitted(true) -> ok;
admitted(false) -> fail(not_its_volume).

%% The root directory read a sector at a time, First the index of the sector's first
%% entry; Long is the long name being gathered across entries and sectors: none, or
%% {long, Next, Sum, Parts}, the order number the next entry must carry, the
%% checksum all carry and the parts read so far, first part first.
lookup(Volume, Name) ->
    root(Volume, Name, 0, none).

root(#volume{root_entries = Count}, _Name, First, _Long) when First >= Count ->
    fail(not_found);
root(Volume = #volume{read = Read, root = Root, root_entries = Count}, Name, First, Long) ->
    Sector = sector(Read, Root + First div ?ENTRIES_PER_SECTOR),
    case entries(Sector, min(?ENTRIES_PER_SECTOR, Count - First), Long, Name) of
        {found, Cluster, Size} -> {Cluster, Size};
        {next, Next} -> root(Volume, Name, First + ?ENTRIES_PER_SECTOR, Next)
    end.

%% The cursor over one sector's Left entries.
entries(_Sector, 0, Long, _Name) ->
    {next, Long};
entries(<<Entry:?ENTRY/binary, Rest/binary>>, Left, Long, Name) ->
    case entry(Entry, Long, Name) of
        {found, _, _} = Found -> Found;
        Next -> entries(Rest, Left - 1, Next, Name)
    end.

entry(<<?END_OF_DIRECTORY, _/binary>>, _Long, _Name) ->
    fail(not_found);
entry(<<?DELETED, _/binary>>, _Long, _Name) ->
    none;
entry(<<Order, Part1:10/binary, Attributes, Type, Sum, Part2:12/binary, LongCluster:16/little,
        Part3:4/binary>>, Long, _Name)
  when Attributes band ?LONG_NAME_MASK =:= ?LONG_NAME ->
    case Type =:= 0 andalso LongCluster =:= 0 of
        true -> long_part(Order, Sum, <<Part1/binary, Part2/binary, Part3/binary>>, Long);
        false -> none
    end;
entry(<<Short:11/binary, Attributes, _:8/binary, _High:16, _:4/binary, First:16/little, Size:32/little>>,
      Long, Name) ->
    case Long of
        {long, 0, Sum, Parts} when Attributes band (?DIRECTORY bor ?VOLUME_ID) =:= 0 ->
            case Sum =:= checksum(Short) andalso long_name(Parts) =:= Name of
                true -> {found, First, Size};
                false -> none
            end;
        _ ->
            none
    end.

%% A long name's entries run from its last, flagged, down to order number 1, each
%% with the same checksum; any other entry starts the gathering again or drops it.
long_part(Order, Sum, Part, _Long) when Order band ?LAST_LONG_ENTRY =/= 0, Order band ?ORDER_MASK >= 1 ->
    {long, Order band ?ORDER_MASK - 1, Sum, [Part]};
long_part(Order, Sum, Part, {long, Order, Sum, Parts}) when Order >= 1 ->
    {long, Order - 1, Sum, [Part | Parts]};
long_part(_Order, _Sum, _Part, _Long) ->
    none.

%% Section 7.2: the sum, rotated right one bit before each byte is added.
checksum(Short) ->
    lists:foldl(fun(Byte, Sum) -> (((Sum band 1) bsl 7) + (Sum bsr 1) + Byte) band 16#ff end, 0,
                binary_to_list(Short)).

%% The long name's UTF-16 code units up to its terminating zero, as Name is given:
%% each ASCII letter in upper case. Name is ASCII, so its bytes are its code units.
long_name(Parts) ->
    Units = [Unit || <<Unit:16/little>> <= iolist_to_binary(Parts)],
    upper(lists:takewhile(fun(Unit) -> Unit =/= 0 end, Units)).

upper(Name) when is_binary(Name) -> upper(binary_to_list(Name));
upper(Units) -> [case Unit of _ when Unit >= $a, Unit =< $z -> Unit - 32; _ -> Unit end || Unit <- Units].

contents(_Volume, _First, 0) ->
    <<>>;
contents(Volume, First, Size) ->
    Sectors = chain(Volume, First, (Size + ?SECTOR - 1) div ?SECTOR, [], []),
    binary:copy(binary:part(iolist_to_binary(Sectors), 0, Size)).

%% The cursor over the chain: Cluster is the next of the Left clusters to read, Seen
%% the clusters read so far and Data their sectors, each last first.
chain(Volume = #volume{read = Read, clusters = Clusters}, Cluster, Left, Seen, Data) ->
    Cluster >= 2 andalso Cluster < Clusters + 2 orelse fail(does_not_read),
    lists:member(Cluster, Seen) andalso fail(does_not_read),
    Sectors = [sector(Read, data_sector(Cluster)) | Data],
    case Left of
        1 -> lists:reverse(Sectors);
        _ -> chain(Volume, next_cluster(Volume, Cluster), Left - 1, [Cluster | Seen], Sectors)
    end.

%% The admitted volume's data area starts at the record's sector, cluster 2.
data_sector(Cluster) -> ?ERX_MEDIUM_RECORD_SELECT_START + Cluster - 2.

%% Cluster's entry in the first FAT, which the admission keeps inside the FAT for
%% every cluster of the data area.
next_cluster(#volume{read = Read, fat = Fat}, Cluster) ->
    Offset = Cluster * 2,
    <<_:(Offset rem ?SECTOR)/binary, Next:16/little, _/binary>> = sector(Read, Fat + Offset div ?SECTOR),
    Next.
