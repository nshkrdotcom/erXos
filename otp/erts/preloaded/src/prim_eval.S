%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2013-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Modified by erXos: 'receive'/2 suspends the receive while its match fun
%% runs. erts_internal:msgq_hand_out/1 holds the message and hands the fun a
%% copy on the heap (edit 77), msgq_finish/2 takes exactly that message or
%% scans on, and msgq_release/1 abandons the receive when the fun raises
%% (edit 78).
%%
%% %CopyrightEnd%
%%
{module, prim_eval}.

%% This module uses low-level BEAM instructions for the message queue facility
%% to allow erl_eval to evaluate receive expressions correctly.

{exports, [{'receive',2},{module_info,0},{module_info,1}]}.

{attributes, []}.

{labels, 16}.


%% y0 the timeout, y1 the match fun, y2 the held message's token, y3 the
%% try around the fun, y4 the fun's result.
{function, 'receive', 2, 2}.
  {label,1}.
    {func_info,{atom,prim_eval},{atom,'receive'},2}.
  {label,2}.
    {allocate,5,2}.
    {init_yregs,{list,[{y,2},{y,3},{y,4}]}}.
    {move,{x,1},{y,0}}.
    {move,{x,0},{y,1}}.
    %% Call arg_reg_alloc() in order to ensure
    %% that def_arg_reg[0] isn't clobbered
    {call,0,{f,9}}.
  {label,3}.
    {loop_rec,{f,6},{x,0}}.
    %% The match fun is ordinary Erlang code, which can run receives of its
    %% own, collect and raise. msgq_hand_out holds the message at the save
    %% pointer and leaves the queue and the timer as a receive finds them on
    %% entry, so the fun matches a copy the process owns. False: the save
    %% pointer moved before the call; scan again. system_limit: nested too
    %% deep, the receive abandoned.
    {'%', {remove_fragility, {x,0}}}.
    {call_ext,1,{extfunc,erts_internal,msgq_hand_out,1}}.
    {test,is_tuple,{f,7},[{x,0}]}.
    {test,test_arity,{f,7},[{x,0},2]}.
    {get_tuple_element,{x,0},1,{y,2}}.
    {get_tuple_element,{x,0},0,{x,0}}.
    {'try',{y,3},{f,5}}.
    {move,{y,1},{x,1}}.
    {call_fun,1}.
    {try_end,{y,3}}.
    {move,{x,0},{y,4}}.
    {test,is_eq_exact,{f,4},[{x,0},{atom,nomatch}]}.
    %% No match: msgq_finish moves past the held message, or back to the
    %% first message if a receive in the fun took it.
    {move,{atom,false},{x,1}}.
    {move,{y,2},{x,0}}.
    {call_ext,2,{extfunc,erts_internal,msgq_finish,2}}.
    {jump,{f,3}}.
  {label,4}.
    %% A match: msgq_finish takes the held message, or answers false when a
    %% receive in the fun took it, and the scan starts again.
    {move,{atom,true},{x,1}}.
    {move,{y,2},{x,0}}.
    {call_ext,2,{extfunc,erts_internal,msgq_finish,2}}.
    {test,is_eq_exact,{f,3},[{x,0},{atom,true}]}.
    {move,{y,4},{x,0}}.
    {deallocate,5}.
    return.
  {label,5}.
    %% The fun raised: abandon the receive and raise again.
    {try_case,{y,3}}.
    {move,{x,1},{y,1}}.
    {move,{x,2},{y,4}}.
    {move,{y,2},{x,0}}.
    {call_ext,1,{extfunc,erts_internal,msgq_release,1}}.
    {bif,raise,{f,0},[{y,4},{y,1}],{x,0}}.
    {deallocate,5}.
    return.
  {label,6}.
    {wait_timeout,{f,3},{y,0}}.
    timeout.
    {move,{atom,timeout},{x,0}}.
    {deallocate,5}.
    return.
  {label,7}.
    {test,is_ne_exact,{f,3},[{x,0},{atom,false}]}.
    {call_ext,1,{extfunc,erlang,error,1}}.

{function, arg_reg_alloc, 0, 9}.
  {label,8}.
    {func_info,{atom,prim_eval},{atom,arg_reg_alloc},0}.
  {label,9}.
    {allocate,0,0}.
    {move,{integer,134217727},{x,0}}.
    {call_ext,1,{extfunc,erlang,bump_reductions,1}}.
    {move,{atom,true},{x,3}}.
    {move,{atom,true},{x,4}}.
    {move,{atom,true},{x,2}}.
    {move,{atom,true},{x,5}}.
    {move,{atom,true},{x,1}}.
    {move,{atom,true},{x,6}}.
    {move,{atom,true},{x,0}}.
    {call_last,7,{f,11},0}.


{function, arg_reg_alloc, 7, 11}.
  {label,10}.
    {func_info,{atom,prim_eval},{atom,arg_reg_alloc},7}.
  {label,11}.
    {move,{atom,ok},{x,0}}.
    return.


{function, module_info, 0, 13}.
  {label,12}.
    {func_info,{atom,prim_eval},{atom,module_info},0}.
  {label,13}.
    {move,{atom,prim_eval},{x,0}}.
    {call_ext_only,1,{extfunc,erlang,get_module_info,1}}.


{function, module_info, 1, 15}.
  {label,14}.
    {func_info,{atom,prim_eval},{atom,module_info},1}.
  {label,15}.
    {move,{x,0},{x,1}}.
    {move,{atom,prim_eval},{x,0}}.
    {call_ext_only,2,{extfunc,erlang,get_module_info,2}}.
