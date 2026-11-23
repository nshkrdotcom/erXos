%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The media the table reader's host tests and fuzz target read
%% (docs/design-drives.md, "Verification"): writers of a sector 0 (an MBR, a FAT
%% boot sector, a protective MBR) and of a GPT with both copies, each a map from
%% sector to its 512 bytes, and read/2, which answers erx_media_table's requests from
%% such a map as the medium's reader does, a sector the map lacks reading as zeros.

-module(erx_media_table_cases).
-export([read/2, read_sectors/2, mbr/1, mbr_sector/2, fat_boot/1, gpt/3, seeds/0]).

-define(SECTOR, 512).
-define(TYPE, <<"erxos test type!">>).
-define(ROUNDS, 5).

%% The table erx_media_table reads from Image; at most sector 0, two headers and two
%% arrays are ever asked for.
read(Capacity, Image) -> element(1, read_sectors(Capacity, Image)).

%% The table, and the sectors read for it, each of them one the table occupies.
read_sectors(Capacity, Image) -> read(Capacity, Image, #{}, ?ROUNDS).

read(Capacity, Image, Seen, Rounds) ->
    case erx_media_table:read(Capacity, Seen) of
        {need, Lbas} when Rounds > 0 ->
            [error({asked_outside_the_medium, Lba}) || Lba <- Lbas, Lba < 0 orelse Lba >= Capacity],
            Read = maps:from_list([{Lba, maps:get(Lba, Image, <<0:(?SECTOR * 8)>>)} || Lba <- Lbas]),
            read(Capacity, Image, maps:merge(Seen, Read), Rounds - 1);
        {need, Lbas} ->
            error({too_many_requests, Lbas});
        Answer ->
            {Answer, maps:keys(Seen)}
    end.

%% Sector 0 holding the four Slots, {Status, Type, Start, Length}, after zero bytes.
mbr(Slots) -> #{0 => mbr_sector(<<0:(446 * 8)>>, Slots)}.

%% Sector 0 holding Slots after the 446 bytes Head.
mbr_sector(Head = <<_:446/binary>>, Slots) ->
    Padded = lists:sublist(Slots ++ lists:duplicate(4, {0, 0, 0, 0}), 4),
    Entries = << <<Status, 0:24, Type, 0:24, Start:32/little, Length:32/little>>
                 || {Status, Type, Start, Length} <- Padded >>,
    <<Head/binary, Entries/binary, 16#55, 16#aa>>.

%% A FAT16 boot sector whose BIOS parameter block is plausible, over Slots.
fat_boot(Slots) ->
    Bpb = <<16#eb, 16#3c, 16#90, "MSDOS5.0", 512:16/little, 4, 1:16/little, 2, 512:16/little,
            0:16/little, 16#f8, 32:16/little, 32:16/little, 64:16/little, 0:32/little,
            65536:32/little, 16#80, 0, 16#29, 16#12345678:32/little, "NO NAME    ", "FAT16   ">>,
    #{0 => mbr_sector(<<Bpb/binary, 0:((446 - byte_size(Bpb)) * 8)>>, Slots)}.

%% A GPT over Capacity sectors listing Entries, {First, Last}, in both copies, laid
%% out as a GPT is (header at 1, array at 2, backup array before the backup header at
%% the last sector), under Options:
%% * array_entries (128) and primary_array_entries: the arrays' entry counts;
%% * usable, {First, Last}: both headers' usable area;
%% * backup_lba, backup_table, primary_table: where the copies lie;
%% * backup_entries: the backup array's own entries;
%% * primary, backup: header fields replaced after the layout (signature, revision,
%%   size, crc, self, alternate, first, last, table, entries, entry_size,
%%   array_crc), crc => bad spoiling the header's CRC;
%% * sector0: sector 0 in place of the protective MBR.
gpt(Capacity, Entries, Options) ->
    Last = Capacity - 1,
    Count = maps:get(array_entries, Options, 128),
    PrimaryCount = maps:get(primary_array_entries, Options, Count),
    ArraySectors = (Count * 128 + ?SECTOR - 1) div ?SECTOR,
    {First, LastUsable} = maps:get(usable, Options, {2 + ArraySectors, Last - 1 - ArraySectors}),
    BackupLba = maps:get(backup_lba, Options, Last),
    BackupTable = maps:get(backup_table, Options, BackupLba - ArraySectors),
    PrimaryTable = maps:get(primary_table, Options, 2),
    PrimaryArray = array(Entries, PrimaryCount),
    BackupArray = array(maps:get(backup_entries, Options, Entries), Count),
    Primary = #{self => 1, alternate => BackupLba, first => First, last => LastUsable, table => PrimaryTable,
                entries => PrimaryCount, entry_size => 128, array_crc => erlang:crc32(PrimaryArray)},
    Backup = Primary#{self => BackupLba, alternate => 1, table => BackupTable, entries => Count,
                      array_crc => erlang:crc32(BackupArray)},
    Sector0 = maps:get(sector0, Options, mbr_sector(<<0:(446 * 8)>>, [{0, 16#ee, 1, min(Last, 16#ffffffff)}])),
    lists:foldl(fun maps:merge/2, #{},
                [spread(PrimaryTable, PrimaryArray), spread(BackupTable, BackupArray),
                 #{1 => header(maps:merge(Primary, maps:get(primary, Options, #{}))),
                   BackupLba => header(maps:merge(Backup, maps:get(backup, Options, #{})))},
                 #{0 => Sector0}]).

array(Entries, Count) ->
    Used = << <<(entry(Number, First, Last))/binary>> || {Number, {First, Last}} <- lists:enumerate(Entries) >>,
    <<Used/binary, 0:((Count * 128 - byte_size(Used)) * 8)>>.

entry(Number, First, Last) ->
    Name = unicode:characters_to_binary(io_lib:format("vol~b", [Number]), utf8, {utf16, little}),
    <<?TYPE/binary, Number:128, First:64/little, Last:64/little, 0:64, Name/binary,
      0:((72 - byte_size(Name)) * 8)>>.

header(Fields = #{self := Self, alternate := Alternate, first := First, last := Last, table := Table,
                  entries := Entries, entry_size := EntrySize, array_crc := ArrayCrc}) ->
    Signature = maps:get(signature, Fields, <<"EFI PART">>),
    Revision = maps:get(revision, Fields, 16#00010000),
    Size = maps:get(size, Fields, 92),
    Body = fun(Crc) ->
                   Bytes = <<Signature/binary, Revision:32/little, Size:32/little, Crc:32/little, 0:32,
                             Self:64/little, Alternate:64/little, First:64/little, Last:64/little,
                             "erxos disk guid!", Table:64/little, Entries:32/little, EntrySize:32/little,
                             ArrayCrc:32/little>>,
                   <<Bytes/binary, 0:((?SECTOR - byte_size(Bytes)) * 8)>>
           end,
    Crc = erlang:crc32(binary:part(Body(0), 0, min(Size, ?SECTOR))),
    case maps:get(crc, Fields, good) of
        good -> Body(Crc);
        bad -> Body((Crc + 1) band 16#ffffffff)
    end.

spread(Lba, Bytes) ->
    maps:from_list([{Lba + Index - 1, Sector}
                    || {Index, Sector} <- lists:enumerate([S || <<S:?SECTOR/binary>> <= Bytes])]).

%% The fuzz target's seeds, {Capacity, Image}: one medium of each scheme.
seeds() ->
    [{4096, mbr([{16#80, 16#0c, 2048, 1000}])},
     {4096, mbr([{0, 16#83, 63, 100}, {0, 16#05, 200, 100}, {0, 16#0c, 300, 3000}, {0, 16#07, 3300, 796}])},
     {4096, fat_boot([])},
     {4096, gpt(4096, [{100, 199}, {200, 4062}], #{})},
     {4096, gpt(4096, [{40, 41}], #{array_entries => 4})},
     {4096, gpt(4096, [{100, 199}], #{backup_lba => 4000, usable => {34, 3900}, primary => #{array_crc => 0}})},
     {4096, gpt(4096, [{100, 199}], #{primary => #{signature => <<"EFI PARX">>}})},
     {64, gpt(64, [{34, 35}], #{array_entries => 4})},
     {4096, gpt(4096, [{100 + 10 * I, 109 + 10 * I} || I <- lists:seq(0, 8)], #{})}].
