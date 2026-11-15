%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_verity_tree).
-moduledoc """
The layout of an EROFS image's dm-verity hash tree (docs/design-storage.md,
"Data model"): how many blocks each level of the tree over an image of a
given number of blocks takes. It is pure arithmetic in a module of its own,
apart from the hash-checking funnel that holds an image's window, so the
package decoder, `erx_pkg_header`, takes a package's tree length from the
layout the hash check is to use, without naming the funnel, which only the
EROFS reader may (docs/design-storage.md, invariant E1).

The tree is dm-verity's, format version 1, with SHA-256 and blocks of
`ERX_EROFS_BLOCK_SIZE` bytes, each holding as many hashes as fit: its lowest
level holds the hash of each image block, each level above holds the hash
of each block of the level below, and the levels stop at the first that
fits in one block, whose hash is the root hash. An image of one block has
no level: its block's hash is the root hash. The packer lays the levels in
the file top first. Both follow the hash tree that Android's avbtool
writes for dm-verity (avbtool.py of platform/external/avb at tag
android-15.0.0_r1, SHA-256
78a50c8620985709f2e131cf948dcd66ecc43f09ed735e09d75751a7e21e4eb8,
`calc_hash_level_offsets` and `generate_hash_tree`, l.4030-4198).
""".

-export([blocks/1, levels/1]).

-include("generated/erx_abi.hrl").

-define(HASHES_PER_BLOCK, (?ERX_EROFS_BLOCK_SIZE div ?ERX_VERITY_HASH_SIZE)).

-doc "The blocks of the hash tree over an image of `ImageBlocks` blocks.".
-spec blocks(pos_integer()) -> non_neg_integer().
blocks(ImageBlocks) ->
    lists:sum(levels(ImageBlocks)).

-doc """
The blocks of each level of the hash tree over an image of `ImageBlocks`
blocks, the lowest level first and the one-block top level last; none for
an image of one block.
""".
-spec levels(pos_integer()) -> [pos_integer()].
levels(1) ->
    [];
levels(Blocks) when is_integer(Blocks), Blocks > 1 ->
    Level = blocks_for(Blocks),
    [Level | levels(Level)].

%% The blocks that hold one hash for each of Count blocks.
blocks_for(Count) ->
    (Count + ?HASHES_PER_BLOCK - 1) div ?HASHES_PER_BLOCK.
