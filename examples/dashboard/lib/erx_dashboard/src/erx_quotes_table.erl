%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_table).
-moduledoc """
The live quotes' source table (examples/dashboard/README.md, "How it
is configured"), fixed in the code: three quotes, each asked of one source,
Kraken's public Ticker API. table/0 answers it in the form
erx_quotes_core:new/2 takes, every period in milliseconds.

A quote asks its sources in order; a source names the URL it is asked
at, the address that URL's host is reached at (erx_quotes connects to
the address and never resolves the name), the JSON path of the price,
the rule for the change, and the credit and note the screen shows. A
source may also name a `history`: the URL that asks it for 15 min
closes, to which erx_quotes_core:history_url/2 adds the start, and the
JSON path of the entries in its answer.
""".

-export([table/0]).

-export_type([table/0, quote/0, source/0, path/0]).

-type path() :: [binary() | non_neg_integer(), ...].
-type history() :: #{url := binary(), entries := path()}.
-type quote() :: #{label := binary(), decimals := 0..8,
                   period := pos_integer(), sources := [atom(), ...]}.
-type source() :: #{url := binary(), address := inet:ip4_address(),
                    format := json, price := path(),
                    change := none | {from, path()},
                    credit := binary(), note := binary(),
                    history => history()}.
-type table() :: #{quotes := [{atom(), quote()}, ...],
                   sources := #{atom() => source()}}.

%% One of api.kraken.com's addresses (Cloudflare's), hardcoded so the
%% kiosk needs no DNS. It may change; the TLS name check still uses the
%% host name of the URL.
-define(KRAKEN_ADDRESS, {104, 16, 14, 28}).
-define(PERIOD_MS, 10000).

-doc "The source table.".
-spec table() -> table().
table() ->
    #{quotes => [quote(btc, <<"Bitcoin">>, kraken_btc),
                 quote(eth, <<"Ether">>, kraken_eth),
                 quote(sol, <<"Solana">>, kraken_sol)],
      sources => #{kraken_btc => kraken(<<"XBTUSD">>, <<"XXBTZUSD">>),
                   kraken_eth => kraken(<<"ETHUSD">>, <<"XETHZUSD">>),
                   kraken_sol => kraken(<<"SOLUSD">>, <<"SOLUSD">>)}}.

quote(Name, Label, Source) ->
    {Name, #{label => Label, decimals => 2, period => ?PERIOD_MS, sources => [Source]}}.

%% Kraken's ticker for `Pair`, which answers under `Key`: `c` is the last
%% trade as [price, volume] and `o` the price at 00:00 UTC. Its history is
%% the OHLC endpoint at the core's bucket, in minutes, answering under the
%% same key.
kraken(Pair, Key) ->
    Minutes = integer_to_binary(erx_quotes_core:bucket() div 60),
    #{url => <<"https://api.kraken.com/0/public/Ticker?pair=", Pair/binary>>,
      address => ?KRAKEN_ADDRESS,
      format => json,
      price => [<<"result">>, Key, <<"c">>, 0],
      change => {from, [<<"result">>, Key, <<"o">>]},
      credit => <<"Kraken">>, note => <<"since 00:00 UTC">>,
      history => #{url => <<"https://api.kraken.com/0/public/OHLC?pair=", Pair/binary,
                            "&interval=", Minutes/binary>>,
                   entries => [<<"result">>, Key]}}.
