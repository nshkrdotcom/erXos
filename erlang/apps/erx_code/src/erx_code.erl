%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code).
-behaviour(gen_server).

-moduledoc """
The code service of the system domain (docs/design-live.md, "Code from the host" and "The
code store"): it keeps the in-memory code store, erx_code_store, and loads modules into the
system domain's runtime by hash.

Every operation is one request term, read by `erx_code_store:read_request/1`, so the host
link's install facet hands `call/1` the term it decoded and nothing else; the other exports
build the same terms for callers in the system domain. A host loads a set of modules in
three steps, sending only what the store lacks: `missing/1` with the modules' hashes,
`put_piece/4` for each piece of each missing blob, then `load/1` with the manifest.

A load is planned whole before it changes anything. The plan names every module's verified
bytes (`erx_code_store:plan_load/2`), and `erx_code_batch:load/1`, which every domain's code
server also loads through, makes the batch current or refuses it whole: either every
module of the manifest is current when `load/1` returns `ok` or none changed. Names become
atoms only here, after the manifest has been read, at most 1,024 of 255 bytes each per
load; a load the loader refuses still leaves its names' atoms behind (TODO.md).
""".

-export([start_link/0, start_link/1, call/1, missing/1, put_piece/4, load/1, history/2]).
-export([init/1, handle_call/3, handle_cast/2, format_status/1]).
-export_type([reply/0]).

%% The system domain's id (docs/design-domains.md: no node has a creation below 4).
-define(SYSTEM_DOMAIN, 4).
-include("generated/erx_abi.hrl").

%% The store's limit: the overlay limit's default (docs/design-live.md, "Overlays").
-define(STORE_LIMIT, ?ERX_CODE_LOAD_BYTES_MAX).
%% A load prepares, purges and loads up to 1,024 modules.
-define(CALL_TIMEOUT, 60000).

-doc """
The answer to a request. A load that `code:prepare_loading/1` or `code:finish_loading/1`
refuses answers `{error, {not_loaded, [{Name, What}]}}`, with `What` as `code:atomic_load/1`
gives it.
""".
-type reply() :: ok
               | {ok, [erx_code_store:hash()]}
               | {ok, erx_code_store:put_reply()}
               | {ok, erx_code_store:history()}
               | {error, bad_request | {bad_manifest, erx_code_store:manifest_error()}
                       | erx_code_store:put_error()
                       | {missing, [erx_code_store:hash()]}
                       | {hash_mismatch, erx_code_store:name()}
                       | {not_loaded, [{erx_code_store:name(), atom()}]}
                       | scope}.

-doc "Starts the code service, registered as `erx_code`, with a store of 16 MiB.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc "As `start_link/0`, with the store's byte limit `limit` from `Options`.".
-spec start_link(#{limit => pos_integer()}) -> gen_server:start_ret().
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, maps:get(limit, Options, ?STORE_LIMIT), []).

-doc """
Serves one request term from outside the code service, as `erx_code_store:read_request/1`
lists them. A term of any other shape answers `{error, bad_request}` and changes nothing.
""".
-spec call(term()) -> reply().
call(Request) ->
    gen_server:call(?MODULE, {request, Request}, ?CALL_TIMEOUT).

-doc "The hashes of `Hashes` whose blobs the store lacks.".
-spec missing([erx_code_store:hash()]) -> reply().
missing(Hashes) ->
    call({missing, Hashes}).

-doc "One piece of the blob `Hash` of `Size` bytes, at `Offset` (`erx_code_store:put_piece/5`).".
-spec put_piece(erx_code_store:hash(), pos_integer(), non_neg_integer(), binary()) -> reply().
put_piece(Hash, Size, Offset, Piece) ->
    call({put, Hash, Size, Offset, Piece}).

-doc "Loads the modules of `Manifest`, `[{Name, Hash}]`, into the system domain as one batch.".
-spec load(term()) -> reply().
load(Manifest) ->
    call({load, Manifest}).

-doc """
The hashes loaded into domain `DomainId` for `Module`, newest first, at most 16, each with
the time of its load in milliseconds of `erlang:system_time/1`. The service loads only into
the system domain, so any other domain answers `{error, scope}`.
""".
-spec history(integer(), module() | binary()) -> reply().
history(DomainId, Module) when is_atom(Module) ->
    history(DomainId, atom_to_binary(Module));
history(DomainId, Module) ->
    call({history, DomainId, Module}).

-doc false.
-spec init(pos_integer()) -> {ok, erx_code_store:store()}.
init(Limit) ->
    {ok, erx_code_store:new(Limit)}.

-doc false.
-spec handle_call({request, term()}, gen_server:from(), erx_code_store:store()) ->
          {reply, reply(), erx_code_store:store()}.
handle_call({request, Term}, _From, Store) ->
    {Reply, Next} = case erx_code_store:read_request(Term) of
                        {ok, Request} -> serve(Request, Store);
                        {error, _} = Refused -> {Refused, Store}
                    end,
    {reply, Reply, Next}.

-doc """
The state as a crash report or `sys:get_status/1` shows it: the store's size and its
blobs' hashes, never its bytes, of the request being served only its kind, and of a
crash's reason only its leading atom (erx_report:reason_name/1), so no report carries
bytes from outside.
""".
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status) ->
    erx_report:status(Status, #{state => fun store_summary/1, message => fun request_kind/1}).

store_summary(Store) when is_map(Store) -> erx_code_store:summary(Store);
store_summary(_State) -> hidden.

request_kind({request, Request}) ->
    {request, erx_report:reason_name(Request)};
request_kind(_Message) ->
    request.

-doc false.
-spec handle_cast(term(), erx_code_store:store()) -> {noreply, erx_code_store:store()}.
handle_cast(_Message, Store) ->
    {noreply, Store}.

serve({missing, Hashes}, Store) ->
    {{ok, erx_code_store:missing(Store, Hashes)}, Store};
serve({put, Hash, Size, Offset, Piece}, Store) ->
    case erx_code_store:put_piece(Store, Hash, Size, Offset, Piece) of
        {ok, Reply, Next} -> {{ok, Reply}, Next};
        {error, Why, Next} -> {{error, Why}, Next}
    end;
serve({load, Manifest}, Store) ->
    case erx_code_store:plan_load(Store, Manifest) of
        {ok, Plan} ->
            case erx_code_batch:load(Plan) of
                ok -> {ok, erx_code_store:commit(Store, Plan, erlang:system_time(millisecond))};
                {error, _} = Failed -> {Failed, Store}
            end;
        {error, _} = Refused ->
            {Refused, Store}
    end;
serve({history, ?SYSTEM_DOMAIN, Name}, Store) ->
    {{ok, erx_code_store:history(Store, Name)}, Store};
serve({history, _DomainId, _Name}, Store) ->
    {{error, scope}, Store}.
