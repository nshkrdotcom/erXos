%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The three messages between a grant and the keeper of its waiting requests
%% (docs/design-files.md, "Serving: the `erx_fs` behaviour", "Waiting
%% requests"), defined once for both sides: the grant, erx_fs, builds the
%% first two and matches the third; erx_fs_waits, the module of every keeper's
%% set of requests, matches the first two and builds the third; and a keeper
%% matches the first in its receive to hand it to erx_fs_waits:hold/2.
%%
%% Wait is {Grant, Alias}: the grant's pid and the alias of its monitor of the
%% keeper, which the first message to it deactivates. Request is the tree's own
%% term for what to do, and Result one of the tree callback's own answers.

%% A request handed to its keeper.
-define(ERX_FS_WAIT(Wait, Request), {erx_fs_wait, Wait, Request}).
%% A flush of a request the keeper holds, sent after the request.
-define(ERX_FS_FLUSH(Wait), {erx_fs_flush, Wait}).
%% The keeper's one answer to a request, sent to the request's alias.
-define(ERX_FS_ANSWER(Alias, Result), {erx_fs_answer, Alias, Result}).
