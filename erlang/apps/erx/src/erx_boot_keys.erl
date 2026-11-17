%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_boot_keys).
-moduledoc """
The decoder of root's `authorized_keys` (docs/design-ssh.md, "Root's login
keys on the medium"): decode/1 takes a file's bytes, those erx_fat_read
answers from the medium's FAT volume or those erx_ssh_dev reads from root's
home copy and the development key's file, and returns the 51-byte key blobs
its lines name, in file order, with a finding for each line it skipped, or
the whole file's refusal.

The file is untrusted input, read as bytes in the subset of sshd(8)'s
AUTHORIZED_KEYS FILE FORMAT the design accepts:

* a line ends at a line feed, a carriage return just before the line feed is
  dropped, and a last line without its line feed counts;
* leading spaces and tabs are skipped, and a line that is then empty or starts
  with `#` is ignored;
* any other line is fields separated by runs of spaces and tabs: the first is
  exactly `ssh-ed25519` or the line is `not_a_plain_key` (options, another key
  type, `cert-authority`); the second is exactly 68 characters of RFC 4648's
  base64 alphabet, whose 51 bytes are the blob of the name `ssh-ed25519` and a
  32-byte key, or the line is `does_not_decode`; the rest, the comment, is
  never read.

The bounds are checked before what they cover is used: a file past 16 KiB is
refused `too_long` before a line is read, a line past 1024 bytes, its line feed
included, is skipped `line_too_long`, and a 17th key refuses the file
`too_many_keys`, since keeping a prefix would drop keys silently. A finding is
`{LineNumber, Reason}` and holds no byte of the file, so nothing a user wrote
reaches a log. A refusal leaves the decoder through one throw,
`{erx_boot_keys, Refusal}`, caught in decode/1.
""".

-include("generated/erx_abi.hrl").

-export([decode/1, file_max/0]).
-export_type([blob/0, finding/0, refusal/0]).

-define(FILE_MAX, 16384).
-define(LINE_MAX, 1024).
-define(KEYS_MAX, 16).
%% 51 bytes are 17 groups of three, so 68 characters with no padding and no spare
%% bits: each blob has one spelling.
-define(KEY_CHARS, 68).

-type blob() :: <<_:408>>.
-type finding() :: {pos_integer(), not_a_plain_key | does_not_decode | line_too_long}.
-type refusal() :: too_long | too_many_keys.

-doc """
The key blobs File's lines name, in file order, and a finding for each line
skipped, or the whole file's refusal.
""".
-spec decode(binary()) -> {ok, [blob()], [finding()]} | {error, refusal()}.
decode(File) ->
    try
        byte_size(File) =< ?FILE_MAX orelse refuse(too_long),
        {Keys, Findings} = lines(File, 1, [], []),
        {ok, Keys, Findings}
    catch
        throw:{?MODULE, Refusal} -> {error, Refusal}
    end.

refuse(Refusal) -> throw({?MODULE, Refusal}).

-doc "The bound on the file, in bytes: a longer file is refused `too_long`.".
-spec file_max() -> pos_integer().
file_max() -> ?FILE_MAX.

%% The cursor over the file's lines: File is what follows the end of line Number - 1.
lines(<<>>, _Number, Keys, Findings) ->
    {lists:reverse(Keys), lists:reverse(Findings)};
lines(File, Number, Keys, Findings) ->
    {Line, Length, Rest} = next_line(File),
    case line(Line, Length) of
        ignored ->
            lines(Rest, Number + 1, Keys, Findings);
        {key, Blob} when length(Keys) < ?KEYS_MAX ->
            lines(Rest, Number + 1, [Blob | Keys], Findings);
        {key, _} ->
            refuse(too_many_keys);
        {skipped, Reason} ->
            lines(Rest, Number + 1, Keys, [{Number, Reason} | Findings])
    end.

%% The next line without its line ending, its length with the line feed, and what
%% follows it.
next_line(File) ->
    case binary:match(File, <<"\n">>) of
        {At, 1} ->
            Rest = binary:part(File, At + 1, byte_size(File) - At - 1),
            {without_cr(binary:part(File, 0, At)), At + 1, Rest};
        nomatch ->
            {File, byte_size(File), <<>>}
    end.

without_cr(Line) ->
    case byte_size(Line) of
        Size when Size > 0, binary_part(Line, Size - 1, 1) =:= <<"\r">> -> binary:part(Line, 0, Size - 1);
        _ -> Line
    end.

line(_Line, Length) when Length > ?LINE_MAX ->
    {skipped, line_too_long};
line(Line, _Length) ->
    case skip_blanks(Line) of
        <<>> -> ignored;
        <<"#", _/binary>> -> ignored;
        Text ->
            case field(Text) of
                {?ERX_SSH_ED25519_NAME_BYTES, AfterType} ->
                    {Key, _Comment} = field(skip_blanks(AfterType)),
                    key(Key);
                {_, _} ->
                    {skipped, not_a_plain_key}
            end
    end.

skip_blanks(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> skip_blanks(Rest);
skip_blanks(Text) -> Text.

%% The field Text starts with, and what follows it.
field(Text) ->
    case binary:match(Text, [<<" ">>, <<"\t">>]) of
        {At, 1} -> {binary:part(Text, 0, At), binary:part(Text, At, byte_size(Text) - At)};
        nomatch -> {Text, <<>>}
    end.

%% base64:decode/1 sees only 68 characters of the alphabet, so it returns 51 fresh
%% bytes and shares nothing with the file.
key(Chars) when byte_size(Chars) =:= ?KEY_CHARS ->
    case lists:all(fun is_base64/1, binary_to_list(Chars)) of
        true -> blob(base64:decode(Chars));
        false -> {skipped, does_not_decode}
    end;
key(_Chars) ->
    {skipped, does_not_decode}.

blob(<<NameSize:32, Name:NameSize/binary, KeySize:32, _:KeySize/binary>> = Blob)
  when Name =:= ?ERX_SSH_ED25519_NAME_BYTES, KeySize =:= ?ERX_SSH_ED25519_KEY_SIZE ->
    {key, Blob};
blob(_Bytes) ->
    {skipped, does_not_decode}.

is_base64(C) ->
    (C >= $A andalso C =< $Z) orelse (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9)
        orelse C =:= $+ orelse C =:= $/.
