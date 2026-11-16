%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_test_user).
-moduledoc """
A `user` for a host test that loads the tree's group.erl (`erl -user
erx_test_user`): it writes what it is given to standard output and answers every
other request but `getopts` `{error, enotsup}`. Stock's user_drv would run a group on the old
code, which a loaded group with another state record would crash.
""".

-export([start/0]).

-spec start() -> pid().
start() ->
    spawn(fun() -> true = register(user, self()), loop() end).

loop() ->
    receive
        {io_request, From, ReplyAs, Request} ->
            From ! {io_reply, ReplyAs, request(Request)};
        _Other ->
            ok
    end,
    loop().

request({put_chars, Encoding, Chars}) ->
    erlang:display_string(stdout, unicode:characters_to_list(Chars, Encoding)),
    ok;
request({put_chars, Encoding, M, F, A}) ->
    request({put_chars, Encoding, apply(M, F, A)});
request({requests, Requests}) ->
    lists:foldl(fun(Request, ok) -> request(Request); (_Request, Error) -> Error end, ok, Requests);
request(getopts) ->
    %% shell:prompt_width/1 asks `user` for the line's encoding.
    [{encoding, unicode}];
request(_Request) ->
    {error, enotsup}.
