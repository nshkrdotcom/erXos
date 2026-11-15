%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_fs).
-moduledoc """
The `apps` tree (docs/design-apps.md, "Interfaces"): the `erx_fs` callback
module the start service serves `ctl` and `rc.conf` with, which a session whose
template holds the `apps` grant mounts at `/apps`, and the system domain mounts
there its own grant of it.

* **Serving.** start_link/0 starts the tree's grants (erx_fs_grants) and names
  them the process behind the system domain's `apps` service
  (erx_facet:serve/2). The domain service asks it, in each grantee's ready
  answer, for one erx_fs grant bound to that domain and ending with it, so a
  session reaches the tree only through a grant the manifest gave its template
  (docs/design-system.md, "Facets of the system domain's services"). One more
  grant, for the system domain itself, is mounted at `/apps` in the system
  domain's namespace (erx_ns:mount_own/2), so the system shell's `service`
  writes the path a session's does (docs/design-shell.md, "Interfaces").
* **rc.conf.** Read-only: an open takes the text the start service's table
  is made from (erx_starter:rc_conf/0) once, and reads see that text until the
  clunk. Every node is owned by uid 0 and has size 0, as a `/proc` file does.
* **ctl.** Write-only. A write is one command line, whatever its offset:
  erx_start_table:parse_ctl/1 parses it, at most 4,096 bytes with one trailing
  newline, and erx_starter:command/1 carries it out within the write. A 9P
  write carries no text back, so a refusal answers an errno (errno/1) and its
  reason goes to the log; the row's own reason is shown at `/proc/apps`.
* **Who may write ctl.** Whoever holds the grant: holding the path is holding
  the control, as for every file server (docs/design.md, Decisions).

Every decision is a pure function of a node, the open flags or the start
service's answer. The effects are the two calls into the start service,
which a test stands in for, and the log line of a refused write.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/0, start_link/1, errno/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4, readdir/4,
         statfs/1, clunk/2, read_mode/0]).

%% The service's name in the manifest, and the tree's name, which a mount's
%% {tree, Name} and attach's Aname name.
-define(SERVICE, apps).
-define(TREE, <<"apps">>).

-type node_() :: root | ctl | rc_conf.
-type errno() :: einval | ebusy | eperm | eagain | eio.

-doc """
Starts the tree's grants, linked to the caller, erx_starter_sup, names them the
process behind the `apps` service, and mounts the system domain's own grant at
`/apps`.
""".
-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link(#{}).

-doc """
As start_link/0, with Args handed to init/1: a test's stand-ins for the start
service, `rc_conf` and `command`.
""".
-spec start_link(map()) -> {ok, pid()}.
start_link(Args) when is_map(Args) ->
    {ok, Grants} = erx_fs_grants:start_link(?MODULE, Args),
    ok = erx_facet:serve(?SERVICE, Grants),
    {ok, Own} = erx_fs_grants:own(Grants),
    ok = erx_ns:mount_own(?SERVICE, Own),
    {ok, Grants}.

-doc """
The errno a ctl write answers for the start service's Answer
(docs/design-apps.md, "Interfaces"): `einval` for a line that does not
parse, `eagain` while rc.conf is unread, `eio` for a command the start
service admitted but could not carry out (rc.conf's write or a start
failed, or the service exited), and for every refusal of the table the
errno erx_start_table:ctl_errno/1 gives it.
""".
-spec errno(erx_starter:answer() | {error, {bad_line, atom()}}) -> ok | {error, errno()}.
errno(ok) -> ok;
errno({error, {bad_line, _Why}}) -> {error, einval};
errno({error, rc_conf_unread}) -> {error, eagain};
errno({error, {failed, _Why}}) -> {error, eio};
errno({error, Refused}) -> {error, erx_start_table:ctl_errno(Refused)}.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(Args) ->
    {ok, maps:merge(defaults(), maps:with([rc_conf, command], Args))}.

%% The start service's two calls the tree makes, which a test's Args stand in for.
defaults() ->
    #{rc_conf => fun erx_starter:rc_conf/0, command => fun erx_starter:command/1}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
walk(root, <<"ctl">>, _Fs) -> found(ctl);
walk(root, <<"rc.conf">>, _Fs) -> found(rc_conf);
walk(root, _Name, _Fs) -> {error, enoent};
walk(_File, _Name, _Fs) -> {error, enotdir}.

found(Node) ->
    {ok, Node, qid(Node)}.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr(ctl, _Fs) -> erx_fs_node:attr(qid(ctl), file, 8#200);
getattr(rc_conf, _Fs) -> erx_fs_node:attr(qid(rc_conf), file, 8#444).

%% ctl opens for writing only; the root and rc.conf for reading only.
-doc false.
open(ctl, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_WRONLY -> {ok, ctl};
        _ -> {error, eacces}
    end;
open(Node, Flags, Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> snapshot(Node, Fs);
        _ -> {error, erofs}
    end.

snapshot(root, _Fs) ->
    {ok, erx_fs_node:listing([{qid(Node), dirent_type(Node), Name}
                              || {Name, Node} <- [{<<"ctl">>, ctl}, {<<"rc.conf">>, rc_conf}]])};
snapshot(rc_conf, #{rc_conf := RcConf}) ->
    %% The table's process may be restarting; the open fails and ends nothing here.
    try RcConf() of
        Text when is_binary(Text) -> {ok, {bytes, Text}}
    catch
        exit:_ -> {error, eio}
    end.

-doc false.
read({bytes, Bytes}, Offset, _Count, _Fs) when Offset >= byte_size(Bytes) ->
    {ok, <<>>};
read({bytes, Bytes}, Offset, Count, _Fs) ->
    {ok, binary:part(Bytes, Offset, min(Count, byte_size(Bytes) - Offset))};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir};
read(ctl, _Offset, _Count, _Fs) ->
    {error, eacces}.

-doc false.
write(ctl, Offset, Bytes, Fs) ->
    case errno(command(Bytes, Fs)) of
        ok -> {ok, byte_size(Bytes), Offset};
        {error, _} = Refused -> Refused
    end;
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

%% The start service's answer to the command line Bytes, or why the line is refused.
%% Each refusal goes to the log: a parse refusal as its reason alone, a command's with
%% the row name parse_ctl/1 admitted, so no text a session wrote reaches the log raw.
command(Bytes, #{command := Command}) ->
    Answer = case erx_start_table:parse_ctl(Bytes) of
                 {ok, Parsed} -> call(Command, Parsed);
                 {error, Why} -> {error, {bad_line, Why}}
             end,
    _ = case Answer of
            ok -> ok;
            {error, Reason} -> logger:notice("apps ctl: refused: ~0P", [Reason, 8])
        end,
    Answer.

%% A call that exits, while the table's process restarts, answers as a failure, so a
%% write ends nothing here.
call(Command, Parsed) ->
    try Command(Parsed)
    catch exit:Reason -> {error, {failed, {exit, Reason}}}
    end.

%% A create of ctl opens it (erx_fs_node:open_by_create/4); rc.conf is read-only, and
%% the tree makes nothing else.
-doc false.
make(root, <<"ctl">>, {file, _Mode, Flags}, Fs) ->
    erx_fs_node:open_by_create(ctl, qid(ctl), Flags, fun(F) -> open(ctl, F, Fs) end);
make(root, <<"rc.conf">>, _What, _Fs) ->
    {error, erofs};
make(_Dir, _Name, _What, _Fs) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk(_Handle, _Fs) ->
    ok.

%% A read is a part of the text the open already took.
-doc false.
read_mode() -> immediate.

%% A node's qid is fixed, the same in every grant: the tree has three nodes.
-spec qid(node_()) -> erx_fs:qid().
qid(root) -> {?ERX_P9_QTDIR, 0, 1};
qid(ctl) -> {0, 0, 2};
qid(rc_conf) -> {0, 0, 3}.

dirent_type(root) -> ?ERX_P9_DT_DIR;
dirent_type(_File) -> ?ERX_P9_DT_REG.
