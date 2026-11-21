%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_log_user).
-moduledoc """
The `user` of a session with no terminal (docs/design-apps.md, "Starting a
session"; docs/design-runtime.md, "The console and standard I/O"): an io server,
registered as `user`, that turns what is written to it into log records under the
session's name, as a UNIX daemon's output with no terminal goes to a log under its
name. erx_session_sup starts it in place of the session's console tty when the
session holds no console facet, so an app's io:format/2 and logger_std_h on
`standard_io` end here.

What is written becomes records by lines (lines/2): each newline ends a line, and
each line that is not empty is one record of level notice, its text the line
without its newline, sent by erx_log_h:write/1 where the domain's logger events
go. Nothing here escapes the text: the sink that shows a record escapes it, tab and
newline included, and names the session. A line not yet ended is held until its
newline comes; a line longer than ?TEXT_MAX bytes is sent in pieces of at most
?TEXT_MAX bytes, each ending at a character's end, so the server never holds more
than ?TEXT_MAX bytes. What it holds when it stops is sent then.

It has no input, as a daemon's standard input is null: a request to read or for
the terminal's geometry is answered `{error, enotsup}` at once. It answers every
request of a process of its own domain and drops any other message: a message from
another domain arrives enveloped, and never as an io request.
""".
-behaviour(gen_server).

-export([start_link/0, lines/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("generated/erx_abi.hrl").

%% The longest text of a record, in bytes: the log interface's log_write_text_max.
-define(TEXT_MAX, ?ERX_LOG_WRITE_TEXT_MAX).
%% The level of every record of a session's output.
-define(LEVEL, notice).
%% The requests of an io server's input, which it has none of.
-define(NO_INPUT, [get_chars, get_line, get_until, get_password, get_geometry]).

-doc "Starts the server, registered as `user` and linked to the caller.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, user}, ?MODULE, [], []).

-doc """
The records' texts of Bytes written after Held, the start of a line held from
before, and the start of a line to hold now: every line ended by a newline that is
not empty, in pieces of at most ?TEXT_MAX bytes, and of a line not yet ended every
piece but its last, which is the one held.
""".
-spec lines(binary(), binary()) -> {[binary()], binary()}.
lines(Held, Bytes) ->
    Parts = binary:split(<<Held/binary, Bytes/binary>>, <<"\n">>, [global]),
    {Ended, [Open]} = lists:split(length(Parts) - 1, Parts),
    {Sent, Rest} = held(pieces(Open)),
    {lists:append([pieces(Line) || Line <- Ended]) ++ Sent, Rest}.

%% Of a line not yet ended, in pieces, those to send now and the last, to hold.
held([]) -> {[], <<>>};
held(Pieces) -> {lists:droplast(Pieces), lists:last(Pieces)}.

%% Line in pieces of at most ?TEXT_MAX bytes, none empty, so an empty line has none.
%% Line is UTF-8, since text/2 made it, so a piece ends at a character's end.
pieces(<<>>) ->
    [];
pieces(Line) when byte_size(Line) =< ?TEXT_MAX ->
    [Line];
pieces(Line) ->
    End = erx_log_h:character_end(Line, ?TEXT_MAX),
    <<Piece:End/binary, Rest/binary>> = Line,
    [Piece | pieces(Rest)].

%%% The server

-doc false.
init([]) ->
    process_flag(trap_exit, true),
    {ok, <<>>}.

-doc false.
handle_call(_Request, _From, Held) ->
    {reply, {error, request}, Held}.

-doc false.
handle_cast(_Message, Held) ->
    {noreply, Held}.

%% A request that fails throws its reason from wherever it fails, and is answered
%% here with the line held before it: a request writes all of its text or none.
-doc false.
handle_info({io_request, From, ReplyAs, Request}, Held) when is_pid(From) ->
    {Reply, Next} = try request(Request, Held)
                    catch throw:{?MODULE, Reason} -> {{error, Reason}, Held}
                    end,
    From ! {io_reply, ReplyAs, Reply},
    {noreply, Next};
handle_info(_Other, Held) ->
    {noreply, Held}.

-doc false.
terminate(_Reason, Held) ->
    send(pieces(Held)).

%% One io request: its reply and the line held after it. The records of a `requests`
%% list are sent once the whole list has been read, so a failing request in it
%% leaves none of the list's text sent.
request(Request, Held) ->
    {Reply, Records, Next} = read(Request, [], Held),
    send(lists:reverse(Records)),
    {Reply, Next}.

%% Request read on top of Records, the texts made so far, newest first: its reply,
%% the texts after it and the line held after it.
read({put_chars, Encoding, Chars}, Records, Held) ->
    put(text(Encoding, Chars), Records, Held);
read({put_chars, Encoding, Module, Function, Args}, Records, Held) ->
    put(text(Encoding, apply_put(Module, Function, Args)), Records, Held);
read({put_chars, Chars}, Records, Held) ->
    read({put_chars, latin1, Chars}, Records, Held);
read({put_chars, Module, Function, Args}, Records, Held) ->
    read({put_chars, latin1, Module, Function, Args}, Records, Held);
read({requests, Requests}, Records, Held) ->
    reads(Requests, Records, Held);
read({setopts, _Options}, Records, Held) ->
    {ok, Records, Held};
read(getopts, Records, Held) ->
    {[{binary, false}, {encoding, unicode}], Records, Held};
read(Request, _Records, _Held) ->
    fail(refusal(Request)).

reads([], Records, Held) ->
    {ok, Records, Held};
reads([Request | Rest], Records, Held) ->
    {_Reply, More, Next} = read(Request, Records, Held),
    reads(Rest, More, Next);
reads(_NoList, _Records, _Held) ->
    fail(request).

%% Why a request this server does not serve fails: enotsup for one that reads, since
%% there is no input, and request for any other.
refusal(Request) when is_tuple(Request), tuple_size(Request) > 0 ->
    refusal(element(1, Request));
refusal(Name) ->
    case lists:member(Name, ?NO_INPUT) of
        true -> enotsup;
        false -> request
    end.

%% What a put_chars request's MFA form makes, run in this process as stock's io
%% servers run it.
apply_put(Module, Function, Args) when is_atom(Module), is_atom(Function), is_list(Args) ->
    try apply(Module, Function, Args)
    catch _:_ -> fail(put_chars)
    end;
apply_put(_Module, _Function, _Args) ->
    fail(put_chars).

%% Chars in Encoding as UTF-8.
text(Encoding, Chars) when Encoding =:= unicode; Encoding =:= latin1 ->
    try unicode:characters_to_binary(Chars, Encoding, unicode) of
        Text when is_binary(Text) -> Text;
        _Incomplete -> fail(put_chars)
    catch
        error:_ -> fail(put_chars)
    end;
text(_Encoding, _Chars) ->
    fail(put_chars).

put(Text, Records, Held) ->
    {Lines, Next} = lines(Held, Text),
    {ok, lists:reverse(Lines, Records), Next}.

-spec fail(atom()) -> no_return().
fail(Reason) ->
    throw({?MODULE, Reason}).

%% Sends each text as a record, then waits until the domain's logger proxy has
%% written them, so a writer waits on the log as stock's `user` makes it wait on its
%% port, and what was written is in the log before the session ends.
send([]) ->
    ok;
send(Texts) ->
    lists:foreach(fun(Text) -> erx_log_h:write({log, ?LEVEL, Text}) end, Texts),
    erx_log_h:sync().
