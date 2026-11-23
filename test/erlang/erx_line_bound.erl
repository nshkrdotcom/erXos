%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The two measures of a line's request that its interface's max_request bounds
%% (docs/design-system.md, "A session's lines", "The grant's quantities"), for the line
%% tests: erlang:external_size/1 of the call {'$gen_call', From, Request}, the envelope
%% left out, and the term's heap words times the word size plus the bytes of every
%% binary it references, each taken with the caller's pid and alias of a node name at
%% its 255-character bound.
-module(erx_line_bound).

-export([measure/1]).

%% The larger of the two measures of Request.
-spec measure(term()) -> pos_integer().
measure(Request) ->
    Call = {'$gen_call', {far_pid(), [alias | far_alias()]}, Request},
    Decoded = erts_debug:flat_size(Call) * erlang:system_info(wordsize) + binary_bytes(Call),
    max(erlang:external_size(Call), Decoded).

%% A node name at the bound of an atom, 255 characters.
node_name() ->
    <<(binary:copy(<<"n">>, 250))/binary, "@host">>.

%% A pid and a reference of that node, read from the external term format: NEW_PID_EXT
%% and NEWER_REFERENCE_EXT with the name as a SMALL_ATOM_UTF8_EXT.
far_pid() ->
    binary_to_term(<<131, 88, 119, 255, (node_name())/binary, 1:32, 0:32, 1:32>>).

far_alias() ->
    binary_to_term(<<131, 90, 3:16, 119, 255, (node_name())/binary, 1:32, 1:32, 2:32, 3:32>>).

%% The bytes of every binary in Term, a heap binary's counted again, which only
%% overstates the measure.
binary_bytes(Binary) when is_binary(Binary) -> byte_size(Binary);
binary_bytes(Tuple) when is_tuple(Tuple) -> binary_bytes(tuple_to_list(Tuple));
binary_bytes([Head | Tail]) -> binary_bytes(Head) + binary_bytes(Tail);
binary_bytes(_Other) -> 0.
