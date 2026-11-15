%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_export).
-moduledoc """
The fixed tree of the session's export (docs/design-files.md, "Narrowing for
a program"; docs/design-programs.md, "Devices"): the `erx_fs` callback module
of the tree that holds `/bin`, `/dev` and `/etc` for the session's programs,
whose handlers walk their fids on it. The session serves it to itself through
two grants of its own domain, an `rx` grant for `/bin`, an `rx` directory,
and an `rw` grant for `/dev` and `/etc`, and each handler narrows what a
program reaches of them.

* **The tree is fixed when the grant starts.** init/1 builds every
  directory's listing and draws each node's qid path from the domain's
  counter (erx_fs_version), so no two files of the tree share a qid path, and
  a grant started again serves new files.
* **Each file's kind and permission bits decide its opens** (file/1): a
  directory opens for reading only, and a file opens for reading or writing
  exactly when its bits let it be read or written, so a command of `/bin`,
  execute-only, never opens; a handler starts a command by its name.
* **`/bin`** lists the session's Erlang commands
  (erx_shell_namespace:commands/1).
* **`/dev`** holds four character devices. `null` reads as empty and takes
  every write; `zero` reads as zeros and takes every write; `urandom` reads
  from the kernel's generator (erx_bytes:entropy/1) and takes no write; and
  `tty` hands its writes to the session's tty (erx_session_tty:write/1),
  which shows them as a terminal does, and answers a read with `enotsup`:
  the tty's readers are the terminal relay's line discipline's to serve.
* **`/etc`** holds `passwd` and `group`, read-only: the session's principal,
  with its number as uid and gid, and `nobody` (65534).
* **A create** of an existing device opens it (erx_fs_node:open_by_create/4),
  since prim_file opens every file it writes through a create, so
  `>/dev/null` reaches `null`; a create of any other name answers `eacces`,
  as the tree's names are its own and fixed.

An open records its access mode, and a read or a write that the mode does not
allow answers `ebadf`, as on UNIX.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4,
         readdir/4, statfs/1, clunk/2]).

-export_type([args/0]).

-doc """
What init/1 takes: the session's principal, the names `/bin` lists, and, for
a test, stand-ins for the kernel's generator and the session's tty.
""".
-type args() :: #{principal := #{name := binary(), number := pos_integer()},
                  commands := [binary()],
                  entropy => fun((1..?ERX_ENTROPY_BYTES_MAX) -> binary()),
                  tty => fun((binary()) -> ok)}.

%% The tree's name, which attach's Aname names.
-define(TREE, <<"export">>).
-define(NOBODY, 65534).

%% A directory, a command of /bin, a device of /dev or a file of /etc.
-type node_() :: root | bin | dev | etc | {command, binary()}
               | null | zero | urandom | tty | passwd | group.
-type access() :: read | write | read_write.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
-spec init(args()) -> {ok, map()}.
init(#{principal := Principal, commands := Commands} = Args) ->
    Dirs = #{root => [{<<"bin">>, bin}, {<<"dev">>, dev}, {<<"etc">>, etc}],
             bin => [{Name, {command, Name}} || Name <- lists:usort(Commands)],
             dev => [{<<"null">>, null}, {<<"tty">>, tty}, {<<"urandom">>, urandom},
                     {<<"zero">>, zero}],
             etc => [{<<"group">>, group}, {<<"passwd">>, passwd}]},
    Files = [Node || Entries <- maps:values(Dirs), {_, Node} <- Entries,
                     not is_map_key(Node, Dirs)],
    Qids = maps:from_list([{Dir, qid(?ERX_P9_QTDIR)} || Dir <- maps:keys(Dirs)]
                          ++ [{File, qid(0)} || File <- Files]),
    {ok, #{dirs => Dirs, qids => Qids, texts => texts(Principal),
           entropy => maps:get(entropy, Args, fun erx_bytes:entropy/1),
           tty => maps:get(tty, Args, fun erx_session_tty:write/1)}}.

%% A qid of Type whose path is drawn from the domain's counter; a counter spent
%% to 2^64 - 1 fails the grant's start.
qid(Type) ->
    {ok, Path} = erx_fs_version:draw(),
    {Type, 0, Path}.

%% The seven fields of a passwd line, as musl's getpwent reads them (name,
%% password, uid, gid, gecos, home and shell), and the four of a group line
%% (name, password, gid and members). No password is set: a session is
%% already its principal's.
texts(#{name := Name, number := Number}) ->
    Id = integer_to_binary(Number),
    Nobody = integer_to_binary(?NOBODY),
    #{passwd => <<Name/binary, ":*:", Id/binary, ":", Id/binary, "::/:/bin/rc\n",
                  "nobody:*:", Nobody/binary, ":", Nobody/binary,
                  ":Unprivileged user:/nonexistent:/usr/sbin/nologin\n">>,
      group => <<Name/binary, ":*:", Id/binary, ":\n", "nobody:*:", Nobody/binary, ":\n">>}.

%% A file's kind and permission bits: what getattr shows and what its opens
%% allow. Every directory is r-x.
-spec file(node_()) -> {file | char, 0..8#777}.
file({command, _}) -> {file, 8#111};
file(Device) when Device =:= null; Device =:= zero; Device =:= tty -> {char, 8#666};
file(urandom) -> {char, 8#444};
file(Text) when Text =:= passwd; Text =:= group -> {file, 8#444}.

-doc false.
root(#{qids := #{root := Qid}}) ->
    {ok, ?TREE, root, Qid}.

-doc false.
walk(Dir, Name, #{dirs := Dirs, qids := Qids}) ->
    case Dirs of
        #{Dir := Entries} ->
            case lists:keyfind(Name, 1, Entries) of
                {Name, Node} -> {ok, Node, map_get(Node, Qids)};
                false -> {error, enoent}
            end;
        #{} ->
            {error, enotdir}
    end.

-doc false.
getattr(Node, #{dirs := Dirs, qids := Qids}) when is_map_key(Node, Dirs) ->
    erx_fs_node:attr(map_get(Node, Qids), dir, 8#555);
getattr(Node, #{qids := Qids}) ->
    {Kind, Mode} = file(Node),
    erx_fs_node:attr(map_get(Node, Qids), Kind, Mode).

-doc false.
open(Node, Flags, #{dirs := Dirs} = Fs) ->
    case {access(Flags), Dirs} of
        {error, _} -> {error, einval};
        {{ok, read}, #{Node := Entries}} -> {ok, {entries, listing(Entries, Fs)}};
        {{ok, _}, #{Node := _}} -> {error, eisdir};
        {{ok, Access}, #{}} -> opened(Node, Access)
    end.

-spec access(non_neg_integer()) -> {ok, access()} | error.
access(Flags) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, read};
        ?ERX_P9_O_WRONLY -> {ok, write};
        ?ERX_P9_O_RDWR -> {ok, read_write};
        _ -> error
    end.

listing(Entries, #{dirs := Dirs, qids := Qids}) ->
    [{map_get(Node, Qids), Offset, dirent_type(Node, Dirs), Name}
     || {Offset, {Name, Node}} <- lists:enumerate(1, Entries)].

dirent_type(Node, Dirs) when is_map_key(Node, Dirs) -> ?ERX_P9_DT_DIR;
dirent_type(Node, _Dirs) ->
    case file(Node) of
        {char, _} -> ?ERX_P9_DT_CHR;
        {file, _} -> ?ERX_P9_DT_REG
    end.

%% A file opens with Access when its permission bits allow every part of it.
opened(Node, Access) ->
    {_Kind, Mode} = file(Node),
    Reads = Mode band 8#444 =/= 0,
    Writes = Mode band 8#222 =/= 0,
    case {Access, Reads, Writes} of
        {read, true, _} -> {ok, {Node, read}};
        {write, _, true} -> {ok, {Node, write}};
        {read_write, true, true} -> {ok, {Node, read_write}};
        _ -> {error, eacces}
    end.

-doc false.
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir};
read({_Node, write}, _Offset, _Count, _Fs) ->
    {error, ebadf};
read({null, _}, _Offset, _Count, _Fs) ->
    {ok, <<>>};
read({zero, _}, _Offset, Count, _Fs) ->
    {ok, <<0:(Count * 8)>>};
read({urandom, _}, _Offset, Count, #{entropy := Entropy}) ->
    random(Count, Entropy);
read({tty, _}, _Offset, _Count, _Fs) ->
    {error, enotsup};
read({Text, _}, Offset, Count, #{texts := Texts}) when Text =:= passwd; Text =:= group ->
    Bytes = map_get(Text, Texts),
    Start = min(Offset, byte_size(Bytes)),
    {ok, binary:part(Bytes, Start, min(Count, byte_size(Bytes) - Start))}.

%% Count bytes of the kernel's generator, which gives at most
%% ERX_ENTROPY_BYTES_MAX a read; a read it refuses answers eio, and nothing
%% else stands in for its bytes.
random(Count, Entropy) ->
    Sizes = lists:duplicate(Count div ?ERX_ENTROPY_BYTES_MAX, ?ERX_ENTROPY_BYTES_MAX)
        ++ [Count rem ?ERX_ENTROPY_BYTES_MAX || Count rem ?ERX_ENTROPY_BYTES_MAX > 0],
    try
        {ok, << <<(Entropy(Size))/binary>> || Size <- Sizes >>}
    catch
        error:{entropy, _Status} -> {error, eio}
    end.

%% Only null, zero and tty open for writing (file/1).
-doc false.
write({_Node, read}, _Offset, _Bytes, _Fs) ->
    {error, ebadf};
write({Sink, _}, Offset, Bytes, _Fs) when Sink =:= null; Sink =:= zero ->
    {ok, byte_size(Bytes), Offset};
write({tty, _}, Offset, Bytes, #{tty := Tty}) ->
    %% A tty that has ended fails the write alone, not the grant.
    try Tty(Bytes) of
        ok -> {ok, byte_size(Bytes), Offset}
    catch
        exit:_ -> {error, eio}
    end;
write({entries, _}, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

-doc false.
make(dev, Name, {file, _Mode, Flags}, Fs) ->
    case walk(dev, Name, Fs) of
        {ok, Device, Qid} ->
            erx_fs_node:open_by_create(Device, Qid, Flags, fun(F) -> open(Device, F, Fs) end);
        {error, enoent} ->
            {error, eacces}
    end;
make(_Dir, _Name, _What, _Fs) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_DEVFS).

-doc false.
clunk(_Handle, _Fs) ->
    ok.
