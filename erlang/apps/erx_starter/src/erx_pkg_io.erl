%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_io).
-moduledoc """
The one taker of the packages' requests and the one owner of the path table
(docs/design-packaging.md, "The package lifetime" and "Identity").

Every request a lifetime of the package process makes on the packages, a
header read, the listing, a deletion or a path entry, comes here and runs
one at a time, each finished before the next is taken. A request names its
lifetime, the erx_pkg pid; one of a lifetime that has ended, or that is not
the one that began last, is refused with `eio` and does nothing. The first
request of each lifetime, `begin_lifetime`, empties the path table, so the
recovery starts from a table no earlier lifetime changes again.

The **path table** maps each listed package, `{Place, FileName}`, to
`pending`, a name the listing holds whose entry has not come, or to its qid
path, drawn from the system domain's file version counter (erx_fs_version)
so no path is given twice in a boot, and its entry from erx_pkg_plan. The
tree's reads come here too, in turn with every other request: `lookup/2`
answers a name's qid path, and `read/5` serves a read of the package the
qid path names, so a read never reads a package its open did not find.

The bytes before the image are served from the header, which a read reads
whole and serves only when its SHA-256 is the one the entry holds, and the
zeros after it to the image; a package the file check refused has no
header hash, and every read of it answers `eio`. So no byte before the
image reaches a reader unauthenticated.

The medium, the module erx_pkg_medium, is the packages as storage holds
them: the image's packages (`system`) and the data partition's `packages/`
directory (`installed`), whose listing answers `{error, absent}` while the
packages grant is not in place. Every call names erx_pkg_medium, since
erx_starter calls no module given to it from outside (docs/design-apps.md,
"Invariants"); the callbacks below are its contract, and every call goes
through `medium/2`, which passes on each answer of the contract and makes
every other one, `eof` among them, `{error, eio}`. A read is bounded here
as well: a read at or past `ERX_PKG_BYTES_MAX`, the largest package, reads
nothing, and one of more than `ERX_PKG_HEADER_MAX` bytes is answered short,
as pread(2) answers.

erx_pkg_io is never restarted (docs/design-packaging.md, "The package
lifetime"): a restarted one could not know whether a request of its
predecessor was still on its way to storage.
""".
-behaviour(gen_server).

-export([start_link/0, request/1, lookup/2, read/5]).
-export([init/1, handle_call/3, handle_cast/2]).
-export_type([place/0]).

-include("generated/erx_abi.hrl").

-type place() :: system | installed.

-doc "Read at most that many entries of `packages/`, and whether more remain.".
-callback list(pos_integer()) -> {ok, [binary()], boolean()} | {error, atom()}.
-doc "The size of a package.".
-callback size(place(), binary()) -> {ok, non_neg_integer()} | {error, atom()}.
-doc "Read a package's bytes from an offset.".
-callback pread(place(), binary(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | {error, atom()}.
-doc "Delete an entry of `packages/`.".
-callback delete(binary()) -> ok | {error, atom()}.

-type request() :: {begin_lifetime, pid()}
                 | {header, pid(), place(), binary()}
                 | {list, pid()}
                 | {delete, pid(), binary()}
                 | {path_entry, pid(), place(), binary(), erx_pkg_plan:entry()}.

-doc "Start the one erx_pkg_io.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Carry out a lifetime's request, after every request taken before it.
`{header, L, Place, File}` answers `{ok, Length, Bytes}`, the file's length
and its first `min(Length, ERX_PKG_HEADER_MAX)` bytes; `{list, L}` answers
`{ok, Names, More}`, at most `ERX_PKG_SCAN_MAX` names; the others answer
`ok`. A storage failure is passed on as `{error, Reason}`.
""".
-spec request(request()) -> term().
request(Request) ->
    gen_server:call(?MODULE, Request, infinity).

-doc """
The qid path of a listed package: `{error, eio}` for a name the listing
holds whose entry has not come, `{error, enoent}` for a name not held.
""".
-spec lookup(place(), binary()) -> {ok, pos_integer()} | {error, eio | enoent}.
lookup(Place, File) ->
    gen_server:call(?MODULE, {lookup, Place, File}, infinity).

-doc """
Read `Size` bytes at `Offset` of the package `{Place, File}` whose qid path
is `Qid`; `{error, eio}` once the name holds another package or none, and
for every read of a package the file check refused.
""".
-spec read(place(), binary(), pos_integer(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | {error, atom()}.
read(Place, File, Qid, Offset, Size) ->
    gen_server:call(?MODULE, {read, Place, File, Qid, Offset, Size}, infinity).

init([]) ->
    {ok, #{lifetime => none, table => #{}}}.

handle_call({begin_lifetime, Lifetime}, _From, State) ->
    case is_pid(Lifetime) andalso is_process_alive(Lifetime) of
        true -> {reply, ok, State#{lifetime := Lifetime, table := #{}}};
        false -> {reply, {error, eio}, State}
    end;
handle_call({lookup, Place, File}, _From, #{table := Table} = State) ->
    Answer = case Table of
                 #{{Place, File} := #{qid := Qid}} -> {ok, Qid};
                 #{{Place, File} := pending} -> {error, eio};
                 #{} -> {error, enoent}
             end,
    {reply, Answer, State};
handle_call({read, _Place, _File, _Qid, Offset, Size}, _From, State)
  when not (is_integer(Offset) andalso Offset >= 0 andalso is_integer(Size) andalso Size >= 0) ->
    {reply, {error, einval}, State};
handle_call({read, _Place, _File, _Qid, Offset, _Size}, _From, State)
  when Offset >= ?ERX_PKG_BYTES_MAX ->
    {reply, {ok, <<>>}, State};
handle_call({read, Place, File, Qid, Offset, Size}, _From,
            #{table := Table} = State) ->
    Answer = case Table of
                 #{{Place, File} := #{qid := Qid, entry := Entry}} ->
                     read_entry(Place, File, Entry, Offset, min(Size, ?ERX_PKG_HEADER_MAX));
                 #{} ->
                     {error, eio}
             end,
    {reply, Answer, State};
handle_call(Request, _From, #{lifetime := Lifetime} = State)
  when element(2, Request) =:= Lifetime, is_pid(Lifetime) ->
    case is_process_alive(Lifetime) of
        true ->
            {Answer, Next} = take(Request, State),
            {reply, Answer, Next};
        false ->
            {reply, {error, eio}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, eio}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% A request of the lifetime that began last, which is alive.
take({header, _, Place, File}, State) ->
    Answer = maybe
        {ok, Length} ?= medium(size, [Place, File]),
        {ok, Bytes} ?= medium(pread, [Place, File, 0, min(Length, ?ERX_PKG_HEADER_MAX)]),
        {ok, Length, Bytes}
    end,
    {Answer, State};
take({list, _}, #{table := Table} = State) ->
    case medium(list, [?ERX_PKG_SCAN_MAX]) of
        {ok, Names, false} = Answer ->
            Held = maps:from_list([{{installed, Name}, pending}
                                   || Name <- Names, erx_pkg_plan:package_file(Name)]),
            {Answer, State#{table := maps:merge(Table, Held)}};
        {ok, _Names, true} = Answer ->
            {Answer, State};
        {error, _} = Error ->
            {Error, State}
    end;
take({delete, _, File}, #{table := Table} = State) ->
    Answer = medium(delete, [File]),
    {Answer, State#{table := maps:remove({installed, File}, Table)}};
take({path_entry, _, Place, File, Entry}, #{table := Table} = State) ->
    case erx_fs_version:draw() of
        {ok, Qid} -> {ok, State#{table := Table#{{Place, File} => #{qid => Qid, entry => Entry}}}};
        {error, eio} = Error -> {Error, State}
    end.

%% A read of a listed package: the bytes before the image from the header
%% its entry authenticates, the rest from the medium.
read_entry(_Place, _File, refused, _Offset, _Size) ->
    {error, eio};
read_entry(Place, File, {accepted, Sha256, Length, Extent}, Offset, Size)
  when Offset < Extent ->
    case medium(pread, [Place, File, 0, Length]) of
        {ok, <<Header:Length/binary>>} ->
            case erx_bytes:sha256(Header) of
                Sha256 ->
                    Before = <<Header/binary, 0:((Extent - Length) * 8)>>,
                    Take = min(Size, Extent - Offset),
                    Head = binary:part(Before, Offset, Take),
                    tail(Place, File, Head, Extent, Size - Take);
                _ ->
                    {error, eio}
            end;
        {ok, _Short} -> {error, eio};
        {error, _} = Error -> Error
    end;
read_entry(Place, File, {accepted, _, _, _}, Offset, Size) ->
    medium(pread, [Place, File, Offset, Size]).

tail(_Place, _File, Head, _Extent, 0) ->
    {ok, Head};
tail(Place, File, Head, Extent, Size) ->
    case medium(pread, [Place, File, Extent, Size]) of
        {ok, Rest} -> {ok, <<Head/binary, Rest/binary>>};
        {error, _} = Error -> Error
    end.

%% The one route of every call on the medium: an answer of the callbacks'
%% contract is passed on, a listing of at most ERX_PKG_SCAN_MAX names and a
%% read of at most the bytes asked; every other answer is a storage failure.
medium(Call, Args) ->
    contract(Call, Args, apply(erx_pkg_medium, Call, Args)).

contract(list, [Max], {ok, Names, More} = Answer)
  when is_list(Names), length(Names) =< Max, is_boolean(More) ->
    case lists:all(fun is_binary/1, Names) of
        true -> Answer;
        false -> {error, eio}
    end;
contract(size, _Args, {ok, Length} = Answer) when is_integer(Length), Length >= 0 ->
    Answer;
contract(pread, [_Place, _File, _Offset, Size], {ok, Bytes} = Answer)
  when is_binary(Bytes), byte_size(Bytes) =< Size ->
    Answer;
contract(delete, _Args, ok) ->
    ok;
contract(_Call, _Args, {error, Reason} = Answer) when is_atom(Reason) ->
    Answer;
contract(_Call, _Args, _Outside) ->
    {error, eio}.
