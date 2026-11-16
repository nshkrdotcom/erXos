%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_verity_tree).
-moduledoc """
The layout of an EROFS image's dm-verity hash tree (docs/design-storage.md,
"Data model"): how many blocks each level of the tree over an image of a
given number of blocks takes, and the one type of a layout, where an image
and its tree lie. It is pure arithmetic in a module of its own, apart from
the hash-checking funnel that holds an image's window, so the package
decoder, `erx_pkg_header`, and the boot record's reader,
`erx_device_record`, make the layout the funnel opens, and the decoder takes
a package's tree length from the arithmetic the hash check uses, without
naming the funnel, which only the EROFS reader may (docs/design-storage.md,
invariant E1). It is
preloaded beside the funnel, which runs in whatever process reads a path,
the code server included, and like it calls no module.

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
-export_type([layout/0]).

-include("generated/erx_abi.hrl").

-define(HASHES_PER_BLOCK, (?ERX_EROFS_BLOCK_SIZE div ?ERX_VERITY_HASH_SIZE)).

-doc """
Where an image and its hash tree lie in a window or a file, in bytes: the
image, `image_length` bytes from `image_offset`, and the tree,
`tree_length` bytes from `tree_offset`, its levels top first; the tree's
salt and its root hash. A package's header gives one, its image after the
header, and the booted slot's `system_image` record another, its image from
byte 0. Its shape is all the type says: the funnel refuses at open a layout
whose blocks do not lie as `blocks/1` and `levels/1` place them.
""".
-type layout() :: #{image_offset := non_neg_integer(), image_length := non_neg_integer(),
                    tree_offset := non_neg_integer(), tree_length := non_neg_integer(),
                    salt := binary(), root_hash := <<_:256>>}.

-doc "The blocks of the hash tree over an image of `ImageBlocks` blocks.".
-spec blocks(pos_integer()) -> non_neg_integer().
blocks(ImageBlocks) ->
    sum(levels(ImageBlocks), 0).

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

%% lists:sum/1, which this module cannot call (lists is not preloaded).
sum([], Sum) -> Sum;
sum([Blocks | Levels], Sum) -> sum(Levels, Sum + Blocks).

%% The blocks that hold one hash for each of Count blocks.
blocks_for(Count) ->
    (Count + ?HASHES_PER_BLOCK - 1) div ?HASHES_PER_BLOCK.
