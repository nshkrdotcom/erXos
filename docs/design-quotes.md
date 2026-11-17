# Live quotes: the kiosk's quotes panel

The kiosk, `examples/dashboard`, shows the clock, the date and live
quotes: its quotes panel shows the prices of Bitcoin, Ether and Solana,
fetched over HTTPS from Kraken's public Ticker API, which needs no key,
each with a graph of its last 24 hours from Kraken's public OHLC API.
It is one package, declared

```text
app dashboard
  needs display net
  applications erx_dashboard
```

and it always shows live quotes. The live quotes are the dashboard's own
modules, `erx_quotes` and the pure modules around it; the dashboard
starts `erx_quotes`, and `erx_dashboard_view` defines the board the two
share. Offline, with no network, each quote shows `no data:` and the
reason. The kiosk is built as a third party builds an app, through the
SDK alone ([design-packaging.md](design-packaging.md#examples)), and it
is the first consumer of the HTTPS client that
[design-crypto.md](design-crypto.md#https-clients) makes a capability of
every session and app: OTP's `ssl` and `httpc` over the `net` grant, with
the image's trust store. This document says what the quotes panel shows,
where its numbers come from, how they refresh and back off, how they show
data that could not be refreshed, how the responses are read, and how
the whole is tested without the internet.

The central construction is that **every number on the screen is a
value paired with the monotonic time it was fetched, or nothing, and the
screen is a pure function of those pairs, the current monotonic time and
the last failure of each quote.** A failure never replaces or alters a
value; it only adds a reason. So whether a value is fresh or stale, and
how old it is, follows from one subtraction, and no path can show a
value `erx_quotes` did not receive or hide how old it is.

Decisions every reader needs:

* **The sources are a table in code.** `erx_quotes_table:table/0` names
  the three quotes, the one source of each, the address it is reached at,
  which field of its answer is the price, how the change is computed and
  what credit the screen gives. It is a demo's table, written once, so it
  is code rather than a file a package carries
  ([The source table](#the-source-table)).
* **No name is resolved.** Each source row carries a hardcoded IPv4
  address; the request connects to it and names the host in the `Host`
  header and in TLS's server name, so the certificate is still checked
  against the host's name ([One request](#one-request)).
* **No byte of a response reaches the screen as text.** The dashboard
  shows numbers it formats itself, the labels and credits of its own table,
  and fixed words for its reasons.
* **HTTPS only, validated as the system validates.** Every row's URL is
  `https`; `erx_quotes` follows a redirect only within the origin it
  asked (the same scheme, host and port), through the same address; and
  its TLS options are the system's defaults with the server name added:
  the image's trust store, the host name checked, TLS 1.3 or 1.2.
* **Nothing is kept across a restart.** A restarted dashboard shows "no
  data" until its first answers, so no value outlives the run that
  fetched it.
* **The graph is a day of closes, or the live samples.** A quote's graph
  is the day of 15 min closes its source's history gave, joined with the
  live prices since; until a history arrives it is the quote's live
  samples, and its status line says which, `24 h` or `live`. A history
  that fails changes no value and no reason, unless it carries a
  `Retry-After`, which holds its source back as a round's does
  ([Asking for a history](#asking-for-a-history)).
* **The dashboard draws; `erx_quotes` owns no window.** `erx_quotes` sends
  the dashboard a board, and the dashboard's view draws it with the clock
  and the date.

## Context

### What the source offers

The endpoint was read with live requests from a development host, and
its documentation page. It needs no key or account.

| Source | Request | Price | Change | Freshness | Trust anchor |
| --- | --- | --- | --- | --- | --- |
| Kraken public REST (`docs.kraken.com`, "Get Ticker Information") | `GET https://api.kraken.com/0/public/Ticker?pair=XBTUSD` (and `ETHUSD`, `SOLUSD`); the answer is `{"error":[],"result":{"XXBTZUSD":{...}}}` | `result.PAIR.c[0]`, the last trade's price, a decimal string | against `o`, the day's opening price at 00:00 UTC, a decimal string | the last trade | GTS Root R4, cross-signed by GlobalSign Root CA |

Each pair's history is Kraken's OHLC endpoint ("Get OHLC Data",
`spot-rest.yaml` lines 514-525), on the same host and with no key:
`GET https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=15&since=T`.
`interval` is one of 1, 5, 15, 30, 60, 240, 1440, 10080 and 21600
minutes, and `since` a Unix time; the answer is
`{"error":[],"result":{"XXBTZUSD":[[time, "open", "high", "low",
"close", "vwap", "volume", count], ...],"last":N}}`, under the same
result key as the ticker's, with at most the 720 most recent entries,
the last one the current bucket, not yet committed, present whatever
`since` names.

The answers for `XBTUSD` and `SOLUSD`, fetched through 104.16.14.28
with the name `api.kraken.com`, have the result keys `XXBTZUSD` and
`SOLUSD`; a key that changes shows as `bad answer`, never
as a wrong price.

`api.kraken.com` is served through Cloudflare. One of its
addresses is 104.16.14.28, the address the table holds. Such addresses
may change; a changed address shows as `cannot connect` or
`certificate rejected`, never as a value, until the table is edited.

The server negotiated TLS 1.3 with an ECDSA P-256 leaf certificate of
about 90 days, so the trust store holds roots, never leaves
([design-crypto.md](design-crypto.md#the-trust-store)).

#### Terms of the source

Kraken's terms of use were not read: the page named for them returned an
error to the fetcher, so whether automated access and public display are
allowed is **unverified**. The kiosk is a demo, not a public service of
record, so the terms are accepted as they stand; the screen credits
Kraken. A deployment that is a public service of record would read them
first.

Others were looked at and left out: CoinGecko's keyless endpoint works,
but its terms require a "Powered by CoinGecko" credit and forbid storing
or redistributing its data (clauses 4.3, 4.1.6 and 6.2 of
`coingecko.com/en/api_terms`); Yahoo's chart endpoint works, but its
terms bar automated collection (2(d)(ix)).

### What exists

* **The HTTPS client** of [design-crypto.md](design-crypto.md#https-clients):
  `ssl`, `public_key`, `crypto`, `asn1` and `inets` in the `app` release,
  `public_key:cacerts_get/0` reading the image's trust store, and
  `httpc` with `max_body_size` bounding every body.
* **The dashboard** (`examples/dashboard`): `erx_dashboard` starts
  `erx_quotes` with `start_link/1` and shows the last
  `{erx_dashboard_board, Board}` it sent; `erx_dashboard_view` defines
  the board and draws it.
* **Apps** of [design-packaging.md](design-packaging.md): the
  declaration, the `apps` row whose `services` are `display data net` on
  both development boards, `erx_app` starting the declared applications
  with their dependencies, the package's files at `/app`.
* **The network** of [design-network-stack.md](design-network-stack.md#the-grant):
  the app's session holds a `net` grant, and `gen_tcp` runs over it
  through `erx_net_client`.
* **The widget toolkit**, which the dashboard's view draws with:
  `erx_ui:open/1` and `erx_ui:tree/2`, the widget schema of
  `abi/formats/ui.txt`, and a renderer that escapes every text property it
  draws ([design-display.md](design-display.md), G5); `erx_ui_host` stands
  in for a display on the host.
* **The wall clock**, which every domain reads from the time page with
  `os:system_time/1`; on an unset clock it reads 1970 plus the uptime
  ([design-time.md](design-time.md#what-erxos-already-has)). The clock's
  `state` at `/proc/time/status` is not the kiosk's to read: its session
  holds no `inspect` grant, and the declaration has no reason to ask for
  one.

## Requirements

* **Q-R1.** Each quote shows the last value `erx_quotes` received for it,
  with the source that gave it and how long ago it was fetched, or that
  it has none.
* **Q-R2.** A value older than its quote's stale age is shown as stale,
  with its age, and never as current.
* **Q-R3.** When a quote's last round failed, the screen says why, in one
  of a closed set of reasons, whether its value is fresh, stale or
  absent, and says "clock not set" when a certificate was refused as
  outside its validity while the wall clock reads before 2000.
* **Q-R4.** `erx_quotes` asks each source at most once per its quote's
  period while the source answers, asks no source before the time its last
  `Retry-After` named, up to an hour, and backs off exponentially, with
  jitter, while every source of a quote fails. It asks a source for a
  quote's history once at start and then at most once an hour,
  answered or not.
* **Q-R5.** Every response is untrusted: its size is bounded before it is
  read, it is parsed by total functions with a fuzz target, and a
  malformed one is a reason, never a crash or a value.
* **Q-R6.** A source is a row of `erx_quotes_table`: changing one, its
  address included, touches no reader, the core or the view.
* **Q-R7.** The kiosk is tested end to end without the internet.

## The construction

The live quotes are a pure core and one effect process. The dashboard's
process starts `erx_quotes` with `start_link/1`, and `erx_quotes` sends
it `{erx_dashboard_board, Board}` whenever the board changes. The
dashboard draws the window; `erx_quotes` owns none.

```text
  erx_quotes (effect process)                         pure modules
  ---------------------------                         ------------
  erx_quotes_table:table/0 ------------------------> the rows the core starts with
  1 s tick, httpc answers, the wall clock ---------> erx_quotes_core: state, rounds,
                                                       backoff, staleness
  httpc:request(get, ...) <------------------------- actions: fetch, history,
                                                       render
  httpc's answer ----------------------------------> erx_quotes_http: status, redirect,
                                                       Retry-After, error -> reason
  the body ----------------------------------------> erx_quotes_extract: body -> value,
                                                       or history -> entries
  {erx_dashboard_board, Board} to the dashboard <--- erx_quotes_view: model -> board
```

* `erx_quotes_core:tick(State, Now, Jitter)` and
  `erx_quotes_core:outcome(State, Quote, Outcome, Now, Jitter)` return the
  next state and a list of actions, `{fetch, Quote, Source, Url}`,
  `{history, Quote, Source}` and `render`; `history/3` and
  `history_failed/5` take a history's entries or its failure. `Now` is
  monotonic milliseconds and `Jitter` a number in `[0.8, 1.2)` the
  effect process draws with `rand`; a value's outcome carries the
  wall-clock second it was read at, which places it in the series. So
  the core reads no clock and no generator and is tested with exact
  values. `render` makes
  the effect process compute the board and send it to the dashboard when
  it differs from the last one it sent.
* `erx_quotes_view:board(State, Now)` is the board the dashboard draws:
  the credit and one quote per row of the table. It is computed from the
  pairs and reasons alone, so the rule of Q-R1 and Q-R2 is in one
  function, `erx_quotes_view:state/3`, which the screen's status line
  and the log's line both take.
* **At start** `erx_quotes` takes the table, starts `ssl` and `inets`
  itself (`application:ensure_all_started/1`), starts the core with every
  quote due and ticks it every second.

The special cases this removes:

* **No "last known good" flag, no cache to invalidate.** A value is
  stored only with its fetch time, so stale is `Now - FetchedAt` above a
  bound, computed when the screen is drawn; nothing marks or clears it.
* **No timer per quote.** One tick a second drives the rounds and the
  ages; a round is due when its quote's `next_at` has passed. Deadlines
  are a field of the state, not timers to cancel, so a round can never
  start twice and a late answer cannot restart a schedule.
* **No source-specific code.** A source's shape is its row's paths; a
  source that changes its format is a row edit, and one whose answer no
  longer matches fails with `bad_data`.
* **A wall clock step changes nothing.** Ages and deadlines are monotonic,
  so a clock set during the run moves no age and no schedule.

## Data model

### The source table

The table is `erx_quotes_table:table/0`, a constant of the dashboard's
code. It is reviewed like any other code, so nothing checks it at run
time. It holds three quotes, each with one source and a period of 10 s:

| Quote | Label | Source | Pair | Result key |
| --- | --- | --- | --- | --- |
| `btc` | Bitcoin | `kraken_btc` | `XBTUSD` | `XXBTZUSD` |
| `eth` | Ether | `kraken_eth` | `ETHUSD` | `XETHZUSD` |
| `sol` | Solana | `kraken_sol` | `SOLUSD` | `SOLUSD` |

One source row, as the module writes it:

```erlang
#{url => <<"https://api.kraken.com/0/public/Ticker?pair=XBTUSD">>,
  address => {104, 16, 14, 28},
  format => json,
  price => [<<"result">>, <<"XXBTZUSD">>, <<"c">>, 0],
  change => {from, [<<"result">>, <<"XXBTZUSD">>, <<"o">>]},
  credit => <<"Kraken">>, note => <<"change since 00:00 UTC">>,
  history => #{url => <<"https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=15">>,
               entries => [<<"result">>, <<"XXBTZUSD">>]}}
```

| Field | Meaning |
| --- | --- |
| `quote` name | an atom naming the quote |
| `label` | the quote's name on the screen, printable ASCII |
| `decimals` | digits after the point |
| `period` | milliseconds between rounds while a source answers |
| `sources` | source names, tried in order; each quote of this table has one |
| `source` name | an atom naming the source |
| `url` | the request, `https`; its host is the name TLS checks and the `Host` header sends |
| `address` | the IPv4 address the request connects to |
| `format` | `json`, the one body format |
| `price` | the path to the price in the JSON answer: binaries are object keys, integers array indexes from 0 |
| `change` | `none`, or `{from, Path}`: the percentage from the value at `Path` to the price |
| `credit` | the source's name on the screen, printable ASCII |
| `note` | what the value is, beside the credit, printable ASCII |
| `history` | optional: `url`, the request for 15 min closes, `https` on the row's host, to which the core adds `since`; `entries`, the path to the list of entries in its answer |

The core takes an ordered list of sources per quote, so a fallback
source is a row and a list entry, not code.

### A quote's state

```erlang
-type quote() :: #{value    := none | {Price :: float(), Change :: none | float(),
                                       Source :: atom(), FetchedAt :: integer()},
                   samples  := [float()],
                   series   := none | [{Start :: integer(), Close :: float()}],
                   history_at := integer(),
                   failure  := none | {Reason :: reason(), At :: integer()},
                   failed_rounds := non_neg_integer(),
                   next_at  := integer(),
                   trying   := none | {Index :: pos_integer(), FirstReason :: none | reason()}}.
-type source() :: #{not_before := integer(), held := none | reason()}.
```

`samples` are the quote's last 180 prices, oldest first. `series` is
`none` until a history arrives, then the day of 15 min buckets of
[Joining live prices](#joining-live-prices), each its start, a
wall-clock second, and its close; `history_at` is the monotonic time
its next history is due.

`value` changes only on a successful outcome, which replaces it whole;
`failure` is set when a round ends with every source failed and cleared
when a round succeeds. `trying` is the round in flight: the index of the
source asked and the first source's reason, if it failed. A source's
`not_before` is the time its last `Retry-After` named; it starts at the time
the core is started (`new/2`'s `Now`), not at 0, since Erlang's monotonic
time can be negative. `held` is the reason the source was held back for,
which a quote that passes the source over takes as its own. Both belong
to the source, so a source two quotes share is held back for both.

## Algorithms

### A round

A quote's round is due when `Now >= next_at` and no round of it is in
flight. The core asks its first source whose `not_before` has passed;
a source still held back is passed over with its `held` reason, the
`{status, 429}` or `{status, 503}` it was held back for. On a source's outcome:

* **a value**: the round ends; `value` is the new pair, `failure` is
  cleared, `failed_rounds` is 0 and `next_at` is `Now + period`;
* **a reason**, with sources left: the core asks the next source that is
  not held back at once, keeping the first source's reason;
* **a reason**, on the last source: the round ends failed; `failure` is
  the first source's reason, since the first source is the one the table
  prefers, `failed_rounds` grows by one, and `next_at` follows the
  backoff below.

Any reason that came with a `RetryAfter` also sets that source's
`not_before` to `Now + RetryAfter`. A round always starts again at the
first source, so a quote returns to its preferred source as soon as that
source answers again and is not held back.

### One request

`erx_quotes` asks for the row's URL with its host replaced by the row's
address, so no name is resolved, and names the host in the `Host` header
and as TLS's server name:

```erlang
%% Url = https://api.kraken.com/0/public/Ticker?pair=XBTUSD, Address = {104,16,14,28}
httpc:request(get, {"https://104.16.14.28/0/public/Ticker?pair=XBTUSD",
                    [{"host", "api.kraken.com"}, {"user-agent", "erxos-quotes/1"},
                     {"connection", "close"}]},
              [{timeout, 20000}, {connect_timeout, 10000},
               {autoredirect, false}, {autoretry, 0},
               {ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                      {server_name_indication, "api.kraken.com"}]}],
              [{sync, false}, {receiver, self()}, {body_format, binary},
               {max_header_size, 10240}, {max_body_size, 65536}])
```

The `ssl` options are the system's defaults
([design-crypto.md](design-crypto.md#https-clients)) with the server name
added: the image's store, peer verification, and no `versions`, so TLS
1.3 or 1.2. Naming `ssl` options at all means naming `cacerts`, or `ssl`
refuses the connection before it starts; verification is never turned
off. `ssl` checks the certificate's name against `server_name_indication`
when it is given, not against the address (`ssl_handshake.erl:3949-3955`),
`httpc` adds its own `server_name_indication` only when the caller names
none (`httpc_handler.erl:1684-1691`), and it sends the caller's `host`
header in place of its own (`httpc.erl:1969`); the host test below pins
all three. So the address decides only where the bytes go: a
server there that cannot show a certificate for `api.kraken.com` from
the image's store gives `certificate rejected`, never a value.

Every request asks for `connection: close`, so `httpc` keeps no
connection alive: it would reuse one by address and scheme alone
(`httpc_manager.erl:875`), and a request for another host name at the
same address would then ride a connection whose certificate was checked
against the first name. Each request opens its own connection, at the
cost of one handshake per quote each period.

The two limits are options of the fourth argument, where `httpc` reads
them; `inets`' edit makes them bound the response's head and body in
every framing ([design-crypto.md](design-crypto.md#otps-applications)).
`autoretry` is 0, so `httpc` never repeats a request on a `Retry-After`
of its own accord and the core alone decides when a source is asked
again. The answer reaches the process as `{http, {RequestId, Result}}`,
and `erx_quotes_http:classify(Result, Url, Hops, WallSeconds)` turns it
into one of, where `Url` is the row's URL and `WallSeconds` the wall
clock, `os:system_time(second)`:

* **`{body, Bytes}`** for status 200 with a binary body; a 200 whose body
  is not a binary is `failed`;
* **`{follow, Url2}`** for status 301, 302, 303, 307 or 308 with one
  `location` header whose value, resolved against `Url` with
  `uri_string:resolve/2`, has the scheme, host and port of `Url`, while
  `Hops` is below 3; the effect process asks `Url2` within the same
  round, through the same address, `Host` header and server name. A
  `location` of bytes outside printable ASCII is refused as `redirect`
  before `uri_string` parses it, since `uri_string` raises on some
  non-ASCII bytes. So every request goes to the origin the table names,
  the server's certificate is checked against that host, and the credit
  the screen shows stays true;
* **`{error, Reason, RetryAfter}`** for anything else, from the table of
  [Reasons](#refusals-and-error-results). `RetryAfter` is the
  `retry-after` header of a 429 or 503 answer when it is a decimal number
  of seconds of at most 10 digits and at least 1, in milliseconds and
  capped at an hour, and `none` otherwise, its date form included.

A body goes to `erx_quotes_extract:value(Source, Bytes)`, which answers
`{ok, Price, Change}` or `{error, bad_data}`.

### Refresh and backoff

After a failed round, in milliseconds,

```text
wait    = min(period * 2^failed_rounds, 900000) * Jitter
next_at = max(Now + wait, the earliest not_before of the quote's sources)
```

So a quote with a period of 10 s waits about 20, 40, 80 s and so on to
15 minutes while its source fails, no round starts while every source of
the quote is held back, a server's `Retry-After` holds back that source
alone, for up to an hour, and quotes that failed together do not retry
together. At most one round and one history request per quote are in
flight, so `erx_quotes` has at most six requests open at once.

### Asking for a history

A quote whose sources include one with a `history` asks the first such
source for it at start and then every hour from its last request,
answered or not, as the action `{history, Quote, Source}`; `history_at`
holds when. A source held back by a `Retry-After` is not asked until its
`not_before`, as by a round. The request is the one of
[One request](#one-request), with the same address, `Host` header,
server name, limits and classifier, for the row's history URL with
`&since=T` added (`erx_quotes_core:history_url/2`): `T` is the wall
clock less a day, rounded down to the start of its 15 min bucket, so
the answer is about 97 entries, about 10 KB. `httpc`'s timeouts end a
request long before the next hour, so at most one history per quote is
in flight.

A history's body goes to `erx_quotes_extract:history/3`, and its
entries to `erx_quotes_core:history/3`, which makes them the quote's
series whole. Its failure, any reason of the
[reasons table](#refusals-and-error-results), is logged as `quotes: btc
history failed: REASON` and goes to `history_failed/5`, where only a
`Retry-After` changes anything: it holds the source back for rounds and
histories alike, as a round's does. Otherwise the quote keeps its
value, its reason and its series, and asks again at the next hour.

### Reading a body

`erx_quotes_extract` is the one reader of response bytes. Its input is
at most 65,536 bytes, the bound `httpc` enforced.

* **The body** is decoded by `json:decode/1` of OTP's `stdlib`, which
  keeps its own stack rather than recursing, so nesting costs heap within
  the input's size (`json.erl:838`, `:881`); object keys stay binaries, so
  no atom is made. The path is walked step by step: a binary step needs
  an object holding that key, an integer step a list long enough. A
  decode error or a step that does not match is `bad_data`.
* **A price** is a JSON number, or a decimal string of at most 32 bytes in
  the grammar `-?[0-9]{1,15}(\.[0-9]{1,12})?`, converted to a float. It
  must be above 0 and below 10^15. A change's reference value is checked
  the same way.

One failure path: every check throws, and `value/2` catches once and
answers `{error, bad_data}`.

### Reading a history

`erx_quotes_extract:history(Source, Bytes, WallSeconds)` reads a
history's body of at most 65,536 bytes through the same decoder, path
walk and price grammar, and answers `{ok, Entries}`, each `{Start,
Close}` oldest first, or `{error, bad_data}`:

* `error` is an empty list;
* the row's `entries` path names a list of 1 to 200 entries, each a
  list of exactly 8 items, destructured after that length is matched;
* each `time` is an integer, a multiple of 900, later than the one
  before, at most two days before the wall clock and no later than the
  bucket after the clock's own, so no entry lies in a future the clock
  has not reached;
* each `close` is a price given as a decimal string, by the grammar and
  bounds of [Reading a body](#reading-a-body);
* every other item is a string or an integer.

One failure path, as for a body: every check throws `bad_data`, which
`history/3` catches once.

### Joining live prices

A series is a list of 15 min buckets on 900 s steps, strictly
increasing, of at most 96, a day. `history/3` builds it from a
history's entries by joining them one by one from an empty list, and a
live price read at wall-clock second `W` joins it the same way:

* in the series' last bucket it replaces that bucket's close;
* in a later bucket it is appended, after one point for each bucket
  skipped, each repeating the last close; only the 96 before the new
  bucket are made, so a long gap costs no more than a day;
* in an earlier bucket, as after the clock stepped back, it is left
  out.

A bucket a history leaves out had no trades, so its close is the one
before, and a history's own gaps are filled whatever their length. A
gap on the kiosk's side is different: no price was known in it. So a
live price that skips more than 4 buckets, an hour, does not join: the
series becomes `none`, the graph falls back to the live samples and the
status line to `live` until the next history, at most an hour away. A
gap of up to 4 buckets repeats the last close, as a missed round or two
would otherwise leave holes in the line, and the graph keeps `24 h`.

The series is then trimmed to its last 96. Each history answer replaces
the series whole, so a price joined across a wrong clock lasts at most
an hour. A quote with no history keeps `series` at `none`: only a
history starts one. The join is pure and tested with exact times.

### What the screen shows

The dashboard's quotes panel, under its header, which carries the board's
credit, `Live quotes`, shows one block per quote in the table's order,
split by hairlines. Each block has the quote's label, its price with
`decimals` digits, its change with two digits after an arrow up or down
and coloured by its direction (a label's `trend`), and a status line that the dashboard shows
under the label in place of the quote's symbol, as the board's quote
carries it (`status` in `erx_dashboard_view`), and under them a graph.
The graph is the closes of the quote's series once a history arrived,
a day; before, it is the quote's last 180 prices, half an hour of its
10 s period, its `samples`. A failed round leaves either as it is. The
day's opening price, derived from the price and its change, is marked
across the graph. `RANGE` in the status line says what the graph
spans, `24 h` or `live`, a fixed word:

| State | Status line |
| --- | --- |
| no value, no failure | `waiting` |
| no value, a failure | `no data: REASON` |
| a value, age at most `3 * period` | `CREDIT[, NOTE], RANGE - AGE`, and `: REASON` when the last round failed |
| a value, older | `stale, AGE - CREDIT[, NOTE], RANGE`, and `: REASON` when the last round failed |

`AGE` is `N s` below two minutes, `N min` below two hours, `N h` below
two days and `N d` beyond, rounded down. A quote with no value has price
and change `none`, which the dashboard shows as `--`. `REASON` is the word
of the [reasons table](#refusals-and-error-results). `erx_quotes` sends a
new board only when it differs from the last one it sent, and the
dashboard hands the toolkit a new tree only when its text changed. The
board's texts are the table's labels and credits, fixed words and numbers
`erx_quotes_view` formats, so no byte of a response reaches the screen.

## Concurrency and failure

* **One process owns the state.** `erx_quotes` holds the core's state, the
  last board it sent, the last log line of each quote and the table of
  requests in flight by `RequestId`.
  An answer whose `RequestId` it does not hold is dropped, so an answer
  that arrives after a restart changes nothing.
* **`erx_quotes` is linked to the dashboard's process**, so the two
  restart together under the dashboard's supervisor. A restart puts every
  quote back at `waiting`; requests in flight are abandoned to `httpc`'s
  timeout, and the dashboard shows no board until the first one arrives.
  Repeated crashes reach the supervisor's intensity, which ends the app,
  and its start row's keeper starts the session again within its own
  intensity ([design-packaging.md](design-packaging.md#starting-an-app)).
* **An application that does not start** stops `erx_quotes` with the
  reason, and the dashboard's start with it, so the session ends with the
  reason, which `/proc/apps` shows.
* **`httpc`'s processes** run under `inets`'s supervisor; a handler that
  crashes answers its request with an error, which is a failed source.
* **The network domain's restart** ends the grant; connections fail with
  their reasons until the domain service grants the session again
  ([design-network-stack.md](design-network-stack.md#the-grant)), and the
  next round uses the new grant.
* **Memory** is bounded by the table and the body limit: at most six
  bodies of 64 KiB and their decoded terms at once, and per quote 180
  samples and a series of 96 points.

## Refusals and error results

| Reason | Shown as | Comes from |
| --- | --- | --- |
| `no_net` | `no network` | `{error, eacces}` from a socket call: the session holds no `net` grant |
| `connect` | `cannot connect` | `econnrefused`, `ehostunreach`, `enetunreach`, or the connect timeout |
| `timeout` | `timed out` | `httpc`'s `timeout` |
| `certificate` | `certificate rejected` | the TLS alerts of a failed path or name check: `bad_certificate` (a host name that does not match included), `unsupported_certificate`, `certificate_revoked`, `certificate_expired`, `certificate_unknown`, `unknown_ca` (`ssl_handshake.erl:2287-2320`) |
| `clock_unset` | `clock not set` | `certificate_expired`, when the wall clock reads before 2000-01-01 |
| `tls` | `TLS failed` | any other TLS alert |
| `{status, Code}` | `HTTP CODE` | a status other than 200 and the followed redirects |
| `redirect` | `bad redirect` | a redirect that leaves the origin asked, one without a usable `location`, or a fourth hop |
| `too_big` | `answer too big` | `body_too_big`, which `inets`' edit answers for a body too big in any framing, or `{header_too_long, _}` |
| `bad_data` | `bad answer` | the extractor's refusal |
| `failed` | `failed` | any answer the classifier does not recognise |

`httpc` reports a connection's failure as `{failed_connect,
[{to_address, Address}, {inet, Options, Reason}]}` (`httpc_handler.erl:784-790`),
and `ssl` an alert as `{tls_alert, {Alert, Description}}` (`ssl.erl:604`);
the classifier matches those shapes and maps an unknown one to `failed`,
so it never names a cause it did not see.

**The clock.** On erXos's kernel the clock is the real-time clock's
reading at boot when the machine has one, so QEMU `virt`'s boots at
`boot`; on Fiasco QEMU `virt`'s is the PL031's reading, which the
system domain's wall-clock keeper sets at boot
([design-time.md](design-time.md#the-real-time-clock-at-boot)); on a
Raspberry Pi 4 without a clock module the clock service starts every
boot at the build's date, `approximate`,
which validation treats as set, so the sources' chains pass from boot
while the image is younger than their certificates; a leaf first valid
after the build date is refused until root's `date` sets the clock exactly
([design-time.md](design-time.md#the-approximate-start)). Only a build
without a date leaves the clock `unset` at 1970-01-01
([design-crypto.md](design-crypto.md#time)). Validation compares
each certificate's dates with the wall clock; an unset clock reads 1970
plus the uptime, before the validity of every certificate a public
authority issues, so `ssl` refuses the source's chain with
`certificate_expired` (`pubkey_cert.erl:155-166`) and the screen shows
nothing it fetched. `erx_quotes` passes the wall clock,
`os:system_time(second)`, as the fourth argument of `classify`, and the classifier turns
`certificate_expired` into `clock_unset` when it reads before
2000-01-01, a time no set clock on a machine erXos runs on shows. Every
other certificate reason, `unknown_ca` among them, stays `certificate`,
since the clock does not decide it.

## Security

* **What the kiosk can reach** is what its `net` grant reaches: every
  address the network stack routes to, this machine's own listeners
  included, and ports above 1,023 to listen on
  ([design-crypto.md](design-crypto.md#security)). `erx_quotes` connects
  only to its table's addresses: it follows no redirect out of the origin
  it asked, and a followed one goes to the same address, so no source can
  send it to another host, this machine's listeners included.
* **What it trusts** is the image's trust store, read-only to every
  domain, and its own code. No name is resolved, so no DNS answer is
  trusted. A source, whoever holds the hardcoded address, or anyone on
  the path can withhold an answer, which shows as a reason; none can make
  the screen show a number that did not come over a connection whose
  certificate the trust store vouches for and whose name is the host of
  the table's URL, which is also the host every redirect stays on.
* **Plain HTTP is unreachable.** Every row is `https`, the classifier
  refuses a redirect to `http`, and `autoredirect` is off, so no value
  arrives over an unauthenticated connection.
* **A hostile source** can make `httpc` hold at most 64 KiB of body and
  10 KiB and one read of head per request, in any framing, at most six
  requests at once, and make `erx_quotes` parse
  them; it cannot make the dashboard crash, allocate past those bounds, create
  an atom, or put text on the screen. A history's closes reach the screen
  only as points of a graph, each a price within the reader's bounds,
  and its times only place them; a series never holds more than 96
  points, whatever the times an answer or the clock give.
* **Text.** The screen's texts are the table's, the kiosk's own words and
  numbers it formats; the renderer escapes every text property anyway
  (G5). Log lines go through the log service's escaping.

## Verification and testing

The host tests run under stock OTP 29.1.2 with nothing but the SDK on
their paths, as the landing gate runs every example's
([design-packaging.md](design-packaging.md#examples)), through
`test/host/erx_quotes_test.rb`. The EUnit suites
`erx_quotes_http_tests`, `erx_quotes_extract_tests`,
`erx_quotes_core_tests` and `erx_quotes_fetch_tests` are in
`examples/dashboard/lib/erx_dashboard/test/`, beside `erx_quotes_fuzz`.
Each test below names the seeded failure that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| rounds (`erx_quotes_core_tests`) | with a test table of two sources for a quote: a first source's failure asks the second at once; a second success shows the second's credit; the next round starts at the first; every source failing sets `failure` to the first's reason | starting the next round at the source that last answered fails the third case |
| held-back sources (`erx_quotes_core_tests`) | the first source answering 429 with `RetryAfter` 3,600,000 ms while the second answers: the next rounds ask only the second until an hour has passed, then the first again; both held back: no request until the earlier `not_before` | keeping `not_before` per quote instead of per source asks the first source ten seconds later |
| backoff (`erx_quotes_core_tests`) | waits in milliseconds for periods of 10,000 and 60,000 over eight failed rounds with `Jitter` 1.0 are exact, capped at 900,000; a success resets the count | dropping the cap gives 2,560,000 at the eighth round |
| staleness and ages (`erx_quotes_core_tests`) | a value shows fresh at `3 * period` after its fetch and stale 1 ms later; a failed round while the value is fresh shows its reason beside the fresh value; ages format at 119 s, 120 s, 7,199 s, 7,200 s and two days | comparing `>=` instead of `>` shows the value stale at exactly `3 * period` |
| log lines (`erx_quotes_core_tests`) | the lines of a waiting quote, a fresh one, the same stale, fresh and then stale after a failed round with `{status, 503}`, one with no data on `clock_unset` and one with no decimals are exact | naming the source rather than the reason of a failed round turns the stale line's `{status,503}` into the source |
| no fabrication (`erx_quotes_core_tests`) | over generated event sequences, every price the board carries is the price of some successful outcome for that quote, with that outcome's credit and an age equal to `Now` minus its time | keeping the previous price on a failed round with a new `FetchedAt` breaks the age property |
| classify (`erx_quotes_http_tests`) | each status, redirect and error shape of the reasons table, built as `httpc` and `ssl` answer, maps to its reason; redirects to `http:`, to another host and to another port of the same host are `redirect`; a relative one is followed; a `location` of non-ASCII bytes is `redirect`; a fourth hop is `redirect`; a 200 whose body is not a binary is `failed`; `retry-after` of 0, 1, 3,600, 7,200, 11 digits and a date give none, 1,000, 3,600,000, 3,600,000, none and none; `certificate_expired` with the wall clock at 1970-01-01T00:05 is `clock_unset`, with it in 2026 `certificate`, and `unknown_ca` at 1970 `certificate` | following a redirect without comparing its host turns the other-host case into `follow` |
| extract (`erx_quotes_extract_tests`) | bodies in the shape of [What the source offers](#what-the-source-offers) for each row of `erx_quotes_table`, generated by the test, give the price and change they carry; a missing key, a wrong type, a 33-byte decimal, `0` and a negative price give `bad_data` | dropping the price's upper bound accepts `1.0e300` |
| history reader (`erx_quotes_extract_tests`) | a generated day of 97 Kraken OHLC entries gives its entries; 200 entries, times two days either side of the clock and integer items are read; each seeded fault of the answer gives `bad_data`: a body of 65,537 bytes, an entry of 7 or 9 items, a close negative, `NaN`, `Infinity`, `1e5`, `0`, 10^15 or a JSON number, times out of order, repeated, off a 900 s step or past two days, no entries, 201 entries, another pair's key, entries in an object, a string time, a float count, a `null` item, a set `error`, a truncated body | dropping the order check accepts the out-of-order answer |
| history requests (`erx_quotes_core_tests`) | a quote whose source names a history asks for it at start, not at 3,599 s and again at 3,600 s, and a table without one asks for none; a round's 429 with an hour's `Retry-After` holds the history back until that hour has passed, and a history's 429 holds back the rounds; the URL's `since` is the start of the bucket a day before the clock | scheduling the next request from an answer never asks again after a failed one |
| join and trim (`erx_quotes_core_tests`) | a live price in the last bucket replaces its close, one in a later bucket is appended after skipped buckets repeating the last close, one in an earlier bucket is left out, and a new history replaces the series whole, its own gap of 9 buckets filled; the series keeps 96 points | dropping the trim of a join keeps all 97 entries of the day |
| gap (`erx_quotes_core_tests`) | a live price after 4 skipped buckets repeats the last close in them and keeps `24 h`; one after 5 makes the series `none` and the status `live`, a later live price leaves it `none`, and the next history brings back `24 h` | filling every gap shows `24 h` across five invented buckets |
| fallback (`erx_quotes_core_tests`) | before a history the graph is the samples and the status says `live`; after one, the series' closes and `24 h`; a table without history keeps no series | starting a series from a live price shows `24 h` before any history |
| frame | `erx_ui_host` with the Erlang renderer draws the dashboard's tree for a fixed time and a fixed live board, one quote of each row of the screen table, `clock not set` among them, equal to the reference picture `dashboard-live` under `test/display/reference/` | showing a stale value without `stale` changes the frame |
| HTTPS on the host (`erx_quotes_fetch_tests`) | the first server also answers the history request with a day of entries, so its quote's status says `24 h`; `erx_quotes`, the effect process, with `public_key`'s `cacerts_path` naming a test root (stock OTP's override, `pubkey_os_cacerts.erl:46`) and a test table whose rows have the address `{127, 0, 0, 1}` and the host `quotes.test`, a name that does not resolve, fetches from an `ssl` server the test runs on the host's loopback with an ECDSA P-256 chain from `public_key:pkix_test_data/1` for `quotes.test`, with the request expression of [One request](#one-request) unchanged, and shows its value; the server answers only a `Host` of `quotes.test` and a request asking for `connection: close` | the server's certificate made for `other.test` shows `certificate rejected`; a 70,000-byte body with its `content-length` shows `answer too big`, and with `max_body_size` moved into the third argument is taken whole; without `connection: close` every quote fails |

**The fuzz target.** `erx_quotes_fuzz`, in
`examples/dashboard/lib/erx_dashboard/test/`, is run by
`tools/fuzz/erx_quotes.rb` from `tools/erx check-fuzz`, at a small budget
at the landing gate and at its configured one by `make check-fuzz`. It
covers the readers of untrusted input of this document and the join:

* **extract:** `erx_quotes_extract:value/2` over bodies of up to 64 KiB
  for each row of `erx_quotes_table`: random bytes; generated answers
  with one field mutated, truncated or moved to a bound; nesting 10,000
  deep; numbers with 400 digits or exponents of `e400`. Properties:
  nothing raises; every accepted price is finite, above 0 and below
  10^15; an unmutated generated answer gives the price it was built
  with. *Seeded failure:* accepting a JSON number without the bound check
  lets `1.0e300` through and fails the bounds property.
* **history:** `erx_quotes_extract:history/3` over bodies of up to
  64 KiB for Bitcoin's row, read at a clock near a random bucket:
  random bytes and the hostile bodies of extract; generated days of
  OHLC entries with one field mutated, truncated or moved to a bound.
  Properties: nothing raises; every accepted list holds 1 to 200
  entries on 900 s steps, strictly increasing, from two days before
  the clock to the bucket after its own, each close above 0 and below
  10^15; an unmutated day gives the entries it was built with. Each
  accepted list then becomes Bitcoin's series and is joined with live
  prices read at random seconds within two hours or two days either
  side: the series stays `none` or 1 to 96 points on 900 s steps,
  strictly increasing, and holds no close that was neither an entry's
  nor a live price. *Seeded failures:* the price bound's removal
  fails the history's bounds property too; dropping the trim of a join
  fails the series property.
* **classify:** `erx_quotes_http:classify/4` over arbitrary terms and
  header lists, redirects included. Property: it raises on nothing and
  answers one of its three shapes.

**The kiosk cell** (`tools/lib/erx/kiosk.rb`) boots the package with no
network device; its reference drawing,
`test/display/reference/dashboard`, is the clock, the date and each
quote at `no data:` with the reason that boot gives, the one
`Kiosk::OFFLINE_REASON` names.

**The QEMU cell**, `kiosk/hvf-1cpu-quotes`, a cell of the kiosk suite
(`tools/lib/erx/kiosk.rb`), checks live quotes against an offline HTTPS
fixture, with the guest's code as it runs on a board. Its image carries
`examples/dashboard`, the package as it ships, on the release medium and
enabled at boot, as the kiosk cell's does, and a trust store with the
fixture's root added after the tree's, through the root files a test
image may name ([design-crypto.md](design-crypto.md#the-trust-store));
naming one makes the image a test image, marked as test code, and only
the cells whose fixture serves HTTPS may name one, which a source check
holds, so no other image's store holds a test root. Its network device is
on restricted QEMU user networking, so nothing the guest sends leaves the
host, with `net=104.16.0.0/16` covering the table's address,
104.16.14.28: libslirp accepts a guest forward only for an address
inside the virtual network (libslirp 4.9.7, `src/slirp.c:1584`) and
answers the guest's ARP for it (`src/slirp.c:1241`). A guest forward for
that address and port 443 names a `cmd:` relay, `nc 127.0.0.1 PORT`,
which QEMU starts for each connection the guest opens, with the
connection as its standard input and output and its arguments split
without a shell (`src/misc.c:212-248`, QEMU 11.1.3 `net/slirp.c:1151`),
joining it to the harness's TLS server. The socket form of the guest
forward does not serve, since it carries every guest connection over one
stream.

The harness's server (`test/fixtures/quotes_fixture.rb`) answers
`/0/public/Ticker?pair=PAIR` with a `Host` of `api.kraken.com` for each
pair of the table with canned bodies in Kraken's shape, and
`/0/public/OHLC?pair=PAIR&interval=15&since=T` with a day of entries
up to `T` plus a day, from an ECDSA P-256 chain made on the host for
`api.kraken.com`. The chain is valid
from the epoch to the end of 9999, its end a GeneralizedTime, so the
cell depends on no clock: a guest whose clock is unset, or set from the
image's build date, trusts it alike. A UTCTime end would not do: OTP's
`public_key` reads a UTCTime `notAfter`'s two-digit year in a window
around the current year, so a clock reading 1970 takes 2049 for 1949.

`erx_quotes` writes one log line per change of a quote's line,
`erx_quotes_view:lines/2`, which names the quote, its state (`waiting`,
`no_data`, `fresh` or `stale`, by the rule of the screen table), the
price as the screen shows it or `--`, and the reason its last round
failed or else the source that gave its value (`none` before any), as
`quotes: btc fresh 64,412.50 kraken_btc` or `quotes: btc no_data --
certificate`; it carries no age, so it changes only when one of those
does. The harness reads the lines from the serial line. The fixture
answers sol's first request with a body of 70,000 bytes and its
`content-length`, and every later request with the pair's price. The
cell passes when sol shows `quotes: sol no_data -- too_big`, the bound
`max_body_size` sets on the target, every quote then reaches `fresh`
with the fixture's prices, and the log says
`quotes: QUOTE history N entries` for each. *Seeded failure:* the
image's trust store taking another root than the fixture's (the
harness's `trusted: false`) makes every quote `no_data -- certificate`.
That a certificate is refused while the clock is unset is the
classifier's host test, not the cell's.

## Alternatives considered

* **A fixture server in the guest.** Rejected: it needs a second test
  app and a name server answering the source's host; the `cmd:` guest
  forward reaches a host server at the table's own address.
* **A table file and a source setting.** Dropped for a demo: a package
  file of sources, its validator and a setting choosing sample or live
  quotes were mechanism no consumer needed; the table is code.
* **Resolving the host name.** Dropped for a hardcoded address: the
  kiosk needs no resolver, and the certificate is still checked against
  the name.
* **A separate quotes app.** Rejected: a second app would open its own
  window beside the dashboard's, or repeat the dashboard's window code.
* **Showing the source's own timestamp.** Not adopted: the age of the
  fetch is what `erx_quotes` knows for certain, and the row's `note`
  says what the value is.
* **Keeping the last values across a restart** in the app's directory.
  Not adopted: it needs `data`, and a value read back after a restart has
  an age the session did not measure.
* **A per-source trust anchor in the table.** Not adopted: the system's
  store serves every app the same way, and the cell tests the store
  itself.

## Open decisions

None.

## References

* Kraken REST API, "Get Ticker Information",
  <https://docs.kraken.com/api/docs/rest-api/get-ticker-information>, and
  its rate limits guide.
* Kraken REST API, "Get OHLC Data",
  <https://docs.kraken.com/api/docs/rest-api/get-ohlc-data> (SHA-256
  `eca28e113ae318b9d65a56abf808ee712b14683afa466aa07f1349ba67cc79d7`),
  and its OpenAPI description <https://docs.kraken.com/openapi/spot-rest.yaml>,
  OpenAPI 3.0.0, version 1.1.0 (SHA-256
  `4e730d0c503de30a57dadd09fd07883af6aa3538e3bc4adabcd0e3576f1d0e1f`),
  both fetched 2026-11-17.
* CoinGecko API terms, <https://www.coingecko.com/en/api_terms>.
* OTP 29.1.2 source archive, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`
  (the pin in `deps.lock`): `lib/inets/src/http_client/httpc.erl`,
  `httpc_handler.erl`; `lib/ssl/src/ssl.erl`, `ssl_handshake.erl`;
  `lib/public_key/src/pubkey_cert.erl`, `pubkey_os_cacerts.erl`;
  `lib/stdlib/src/json.erl`.
