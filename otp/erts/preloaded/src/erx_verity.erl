%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_verity).
-moduledoc """
The hash-checking reader of EROFS images (docs/design-storage.md, Reading
EROFS images, and invariant E1): the one funnel through which the EROFS
reader, `erx_erofs`, reaches an image's blocks.

`open/2` takes the pid of the block service's window on the image and the
image's layout: the image's length and its dm-verity hash tree's offset
and length in the window, the tree's salt and its root hash. It asks the
window its length, refuses a layout whose image is not whole blocks, whose
tree does not start on a block at or past the image's end, is not as long
as `erx_verity_tree` gives for the image, or does not fit the window, and
returns an opaque handle that holds the pid and the layout. Nothing in the
handle's value stops a module from taking the window out of it; what keeps
every other module on `read/3` is the build check `Erx::ErofsReads`, which
refuses any module but the reader that names this one and keeps the
reader's own calls to the funnel and to modules that reach no state.

`read/3` runs in the calling process, so a slow read delays only its
caller. It checks the request against the image's size and the per-call
limit, and sends the window one request for each block it needs, all at
once: the data blocks asked for and, on each level of the tree, the blocks
that hold their hashes. Each is a `gen_server` call with an alias of its
own, so each answer is matched to its block whatever order they come in.
Each answer must be a whole block, its block the one its alias names; then it checks the
tree level by level, top first, in `check/3`: the top block against the
root hash, each lower block against its hash in the level above, and each
data block against its hash in the lowest level, every hash the SHA-256 of
the salt and the block. It returns the data blocks only if every one
matched, each a binary of `ERX_EROFS_BLOCK_SIZE` bytes. Every failure, a
bad request, a refused, short or late answer, a window that ended and a
block that does not match its hash included, answers `{error, eio}`. A
call waits at most `ANSWER_WAIT` for each request; its aliases end with
it, so an answer that arrives later is dropped by the runtime, and one
that arrived as it ended is taken out of the mailbox. Like the reader, it
calls only BIFs and preloaded modules, the SHA-256 built-ins of
`erx_bytes` and `erx_verity_tree`, since it runs in whatever process reads
a path, the code server included.

The tree `unchecked` opens a window that has no layout, the image mounts
of `erx_ns`, whose blocks pass through unchecked until the security
closure (docs/plan.md, M11).
""".

-export([open/2, read/3]).
-export_type([image/0, tree/0, layout/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).
%% The window's sectors in one image block.
-define(SECTORS, (?BLOCK div ?ERX_VIRTIO_BLK_SECTOR_SIZE)).
%% The hashes one tree block holds.
-define(HASHES, (?BLOCK div ?ERX_VERITY_HASH_SIZE)).
%% How long a call waits for each of the window's answers, its deadline this times the
%% requests it sends, since the window answers them one at a time: longer than the
%% window's own wait for the device process (35 s in erx_blk_window), so a window that
%% answers a device that did not is heard first.
-define(ANSWER_WAIT, 40000).

%% An open image: its window, its size in blocks and how its blocks are checked, either
%% unchecked or the tree's salt, root hash and the window block where each of its levels
%% starts, the lowest level first.
-record(window, {pid :: pid(),
                 blocks :: non_neg_integer(),
                 tree :: unchecked | #{salt := binary(), root_hash := <<_:256>>,
                                       levels := [non_neg_integer()]}}).

-doc "An open image: its window, which only this module reads through.".
-opaque image() :: #window{}.

-doc """
Where the image and its hash tree lie in the window, in bytes: the image
from byte 0, `image_length` bytes, and the tree, `tree_length` bytes from
`tree_offset`, its levels top first; the tree's salt and its root hash.
""".
-type layout() :: #{image_length := pos_integer(), tree_offset := non_neg_integer(),
                    tree_length := non_neg_integer(), salt := binary(), root_hash := <<_:256>>}.

-doc """
How the image's blocks are checked: against the tree a layout places, or
`unchecked`, for a window that has no layout.
""".
-type tree() :: layout() | unchecked.

-doc """
Opens the image the window `Window` holds under `Tree`, or answers
`{error, eio}` when the window does not say its length or the layout does
not fit it.
""".
-spec open(pid(), tree()) -> {ok, image()} | {error, eio}.
open(Window, Tree) when is_pid(Window) ->
    case call(Window, [info]) of
        {ok, [{ok, #{sectors := Sectors}}]} when is_integer(Sectors), Sectors >= 0 ->
            opened(Window, Sectors div ?SECTORS, Tree);
        _ ->
            {error, eio}
    end;
open(_, _) ->
    {error, eio}.

opened(Pid, WindowBlocks, unchecked) ->
    {ok, #window{pid = Pid, blocks = WindowBlocks, tree = unchecked}};
opened(Pid, WindowBlocks, #{image_length := Length, tree_offset := TreeOffset,
                            tree_length := TreeLength, salt := Salt, root_hash := <<_:256>> = Root} = Layout)
  when map_size(Layout) =:= 5, is_integer(Length), Length > 0, Length rem ?BLOCK =:= 0,
       is_integer(TreeOffset), TreeOffset >= Length, TreeOffset rem ?BLOCK =:= 0,
       TreeOffset div ?BLOCK =< WindowBlocks,
       is_integer(TreeLength), is_binary(Salt) ->
    Blocks = Length div ?BLOCK,
    Levels = erx_verity_tree:levels(Blocks),
    TreeBlocks = erx_verity_tree:blocks(Blocks),
    case TreeLength =:= TreeBlocks * ?BLOCK andalso TreeOffset div ?BLOCK + TreeBlocks =< WindowBlocks of
        true ->
            Starts = starts(reverse(Levels, []), TreeOffset div ?BLOCK, []),
            {ok, #window{pid = Pid, blocks = Blocks,
                         tree = #{salt => Salt, root_hash => Root, levels => Starts}}};
        false ->
            {error, eio}
    end;
opened(_, _, _) ->
    {error, eio}.

%% The window block where each level starts, the lowest first, from the levels' lengths
%% top first, as they lie from the tree's first block At.
starts([], _At, Starts) -> Starts;
starts([Blocks | Levels], At, Starts) -> starts(Levels, At + Blocks, [At | Starts]).

-doc """
Returns `Count` blocks of the image from block `Block`, 1 to
`ERX_VERITY_READ_BLOCKS_MAX` of them, each a binary of
`ERX_EROFS_BLOCK_SIZE` bytes that matched the image's tree, or
`{error, eio}`.
""".
-spec read(image(), non_neg_integer(), pos_integer()) -> {ok, [binary()]} | {error, eio}.
read(#window{pid = Pid, blocks = Blocks, tree = Tree}, Block, Count)
  when is_integer(Block), Block >= 0, is_integer(Count),
       Count >= 1, Count =< ?ERX_VERITY_READ_BLOCKS_MAX, Block + Count =< Blocks ->
    Last = Block + Count - 1,
    Paths = paths(Tree, Block div ?HASHES, Last div ?HASHES),
    Wanted = [{Block, Last} | [{Start + First, Start + End} || {Start, First, End} <- Paths]],
    Requests = [{read, At * ?SECTORS, ?SECTORS} || {From, To} <- Wanted, At <- indexes(To, From, [])],
    case call(Pid, Requests) of
        {ok, Answers} -> checked(Tree, Block, Count, Paths, Answers);
        error -> {error, eio}
    end;
read(_, _, _) ->
    {error, eio}.

%% The blocks that hold the hashes of blocks First to Last of the level below, on each
%% level, the lowest first: {Start, FirstIndex, LastIndex}, Start the level's first
%% window block. An unchecked image needs none.
paths(unchecked, _First, _Last) ->
    [];
paths(#{levels := Starts}, First, Last) ->
    paths(Starts, First, Last, []).

paths([], _First, _Last, Paths) ->
    reverse(Paths, []);
paths([Start | Starts], First, Last, Paths) ->
    paths(Starts, First div ?HASHES, Last div ?HASHES, [{Start, First, Last} | Paths]).

%% The data blocks, once every answer is a whole block and, over a tree, every block
%% matched its hash.
checked(Tree, Block, Count, Paths, Answers) ->
    case whole(Answers, []) of
        {ok, Read} ->
            {Data, TreeRead} = split(Count, Read, []),
            case Tree of
                unchecked -> {ok, Data};
                #{} -> check(Tree, {Block, Data}, levels(Paths, TreeRead, []))
            end;
        error ->
            {error, eio}
    end.

whole([], Blocks) ->
    {ok, reverse(Blocks, [])};
whole([{ok, Block} | Answers], Blocks) when is_binary(Block), byte_size(Block) =:= ?BLOCK ->
    whole(Answers, [Block | Blocks]);
whole(_, _) ->
    error.

%% Each level's blocks read, as {FirstIndex, Blocks}, the top level first.
levels([], [], Levels) ->
    Levels;
levels([{_Start, First, Last} | Paths], Read, Levels) ->
    {Blocks, Rest} = split(Last - First + 1, Read, []),
    levels(Paths, Rest, [{First, Blocks} | Levels]).

%% The pure check: each level of the tree, the top first, against the level above it,
%% the root hash standing above the top as a level of one block holding one hash, and the
%% data blocks against the lowest level. A level is {FirstIndex, Blocks}.
check(#{salt := Salt, root_hash := Root}, Data, Levels) ->
    check(Salt, {0, [Root]}, Levels, Data).

check(Salt, Parent, [Level | Levels], Data) ->
    case matches(Salt, Parent, Level) of
        true -> check(Salt, Level, Levels, Data);
        false -> {error, eio}
    end;
check(Salt, Parent, [], {_, Blocks} = Data) ->
    case matches(Salt, Parent, Data) of
        true -> {ok, Blocks};
        false -> {error, eio}
    end.

%% Whether each block of a level, index First onwards, hashes to its slot in the parent
%% level: block I's hash is hash I of the parent level, its parent blocks read from index
%% ParentFirst, HASHES hashes in each (the root, at index 0, is the one hash). A block
%% whose slot lies outside the parent blocks read does not match.
matches(Salt, {ParentFirst, Parents}, {First, Blocks}) ->
    Hashes = iolist_to_binary(Parents),
    SlotOffset = (First - ParentFirst * ?HASHES) * ?ERX_VERITY_HASH_SIZE,
    SlotOffset >= 0 andalso SlotOffset =< byte_size(Hashes)
        andalso hashed(Salt, binary:part(Hashes, SlotOffset, byte_size(Hashes) - SlotOffset), Blocks).

%% Whether each block hashes to the next hash of Hashes.
hashed(_Salt, _Hashes, []) ->
    true;
hashed(Salt, <<Hash:?ERX_VERITY_HASH_SIZE/binary, Hashes/binary>>, [Block | Blocks]) ->
    Hash =:= hash(Salt, Block) andalso hashed(Salt, Hashes, Blocks);
hashed(_Salt, _Hashes, _Blocks) ->
    false.

hash(Salt, Block) ->
    erx_bytes:sha256_final(erx_bytes:sha256_update(erx_bytes:sha256_update(erx_bytes:sha256_init(), Salt), Block)).

%% The window's answers to Requests, in order, or error once one is missing: the window
%% ended or did not answer by the deadline. Each request is a gen_server call made by
%% hand, since gen_server is not preloaded: {'$gen_call', {Pid, Tag}, Request}, whose
%% Tag [alias | Alias] is gen's form for a reply sent to the alias Alias. Each request has
%% its own reply alias, so an answer can only be its own request's; the monitor, which
%% ends with the call, sees the window end.
call(Pid, Requests) ->
    Monitor = monitor(process, Pid),
    Tags = [[alias | alias([reply])] || _ <- Requests],
    _ = [Pid ! {'$gen_call', {self(), Tag}, Request} || {Tag, Request} <- zip(Tags, Requests)],
    Deadline = erlang:monotonic_time(millisecond) + ?ANSWER_WAIT * length(Requests),
    Answers = answers(Monitor, Tags, Deadline, []),
    demonitor(Monitor, [flush]),
    _ = [unalias(Alias) || [alias | Alias] <- Tags],
    drop(Tags),
    Answers.

answers(_, [], _, Answers) ->
    {ok, reverse(Answers, [])};
answers(Monitor, [Tag | Tags], Deadline, Answers) ->
    receive
        {Tag, Answer} -> answers(Monitor, Tags, Deadline, [Answer | Answers]);
        {'DOWN', Monitor, process, _, _} -> error
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error
    end.

%% An answer that arrived after its call gave up, before its alias ended.
drop(Tags) ->
    _ = [receive {Tag, _} -> ok after 0 -> ok end || Tag <- Tags],
    ok.

%% lists:seq/2, lists:split/2, lists:zip/2 and lists:reverse/2, which this module cannot
%% call (lists is not preloaded): From to To in order onto a tail, a list's first N
%% elements and the rest, two lists paired, and a list reversed onto a tail. As indexes/3
%% makes no index of an empty range, split/3 takes no element for a count below one.
indexes(To, From, Indexes) when To < From -> Indexes;
indexes(To, From, Indexes) -> indexes(To - 1, From, [To | Indexes]).

split(N, List, Taken) when N =< 0 -> {reverse(Taken, []), List};
split(N, [Head | List], Taken) -> split(N - 1, List, [Head | Taken]).

zip([A | As], [B | Bs]) -> [{A, B} | zip(As, Bs)];
zip([], []) -> [].

reverse([], Tail) -> Tail;
reverse([Head | List], Tail) -> reverse(List, [Head | Tail]).
