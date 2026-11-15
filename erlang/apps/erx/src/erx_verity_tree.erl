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
fits in one block, whose hash is the root hash.
""".

-export([blocks/1, levels/1]).

-include("generated/erx_abi.hrl").

-define(HASHES_PER_BLOCK, (?ERX_EROFS_BLOCK_SIZE div ?ERX_VERITY_HASH_SIZE)).

-doc "The blocks of the hash tree over an image of `ImageBlocks` blocks.".
-spec blocks(pos_integer()) -> pos_integer().
blocks(ImageBlocks) ->
    lists:sum(levels(ImageBlocks)).

-doc """
The blocks of each level of the hash tree over an image of `ImageBlocks`
blocks, the lowest level first and the one-block top level last.
""".
-spec levels(pos_integer()) -> [pos_integer(), ...].
levels(ImageBlocks) when is_integer(ImageBlocks), ImageBlocks >= 1 ->
    case blocks_for(ImageBlocks) of
        1 -> [1];
        Level -> [Level | levels(Level)]
    end.

%% The blocks that hold one hash for each of Count blocks.
blocks_for(Count) ->
    (Count + ?HASHES_PER_BLOCK - 1) div ?HASHES_PER_BLOCK.
