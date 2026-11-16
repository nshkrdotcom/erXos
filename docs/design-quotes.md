# Live quotes: the full kiosk's source

The kiosk has two milestones. The **basic kiosk**, `examples/dashboard`
with its default source `erx_dashboard_sample`, shows the clock, the date
and made-up sample quotes. It has no remote data, works offline and never
needs the network. The **full kiosk** is the same dashboard with live
quotes, the subject of this document: its quotes panel shows the prices
of Bitcoin, Ether and the S&P 500, fetched over HTTPS from public
endpoints that need no key. The live quotes are the dashboard's own
modules, `erx_quotes` and the pure modules around it, a quotes source of
the dashboard's seam `erx_dashboard_source`; the basic kiosk never starts
`erx_quotes`, and its release needs neither `ssl` nor `inets`. The full
kiosk is built as a third party builds an app, through the SDK alone
([design-packaging.md](design-packaging.md#examples)), and it is the
first consumer of the HTTPS client that
[design-crypto.md](design-crypto.md#https-clients) makes a capability of
every session and app: OTP's `ssl` and `httpc` over the `net` grant, with
the image's trust store. This document says what the quotes panel shows,
where its numbers come from, how they refresh and back off, how they show
data that could not be refreshed, how the responses are read, and how
the whole is tested without the internet.

**What the full kiosk declares.** The dashboard is one application,
`erx_dashboard`, whose `source` environment value names the quotes
source it starts and whose `quotes_table` names the table's path. The
basic kiosk's declaration is

```text
app dashboard
  needs display
  applications erx_dashboard
```

with `source` at its default, `erx_dashboard_sample`. The full kiosk is
the same application directory declared with `needs display net`, with
`source` set to `erx_quotes` and `quotes_table` to `/app/share/quotes.config`
(the default), the package carrying the table as `share/quotes.config`
([Open decisions](#open-decisions) names how a package sets the value).

The central construction is that **every number on the screen is a
value paired with the monotonic time it was fetched, or nothing, and the
screen is a pure function of those pairs, the current monotonic time and
the last failure of each quote.** A failure never replaces or alters a
value; it only adds a reason. So whether a value is fresh or stale, and
how old it is, follows from one subtraction, and no path can show a
value `erx_quotes` did not receive or hide how old it is.

Decisions every reader needs:

* **The sources are data.** Which endpoints `erx_quotes` asks, which field of
  each answer is the price, how the change is computed and what credit
  the screen gives are rows of the table, `share/quotes.config` in the
  package. The
  code knows two body formats, JSON and CSV, and three change rules; a
  new source is a row, not code ([The source table](#the-source-table)).
* **Each quote has an ordered list of sources.** A round tries them in
  order until one gives a value; the screen names the source that did.
* **No byte of a response reaches the screen as text.** The dashboard
  shows numbers it formats itself, the labels and credits of its own table,
  and fixed words for its reasons.
* **HTTPS only, to the table's hosts only, validated as the system
  validates.** The table refuses a URL that is not `https`, `erx_quotes`
  follows a redirect only within the origin it asked (the same scheme,
  host and port), and it passes no TLS option, so every connection takes the
  defaults of [design-crypto.md](design-crypto.md#https-clients): the
  image's trust store, the server's host name checked, TLS 1.3 or 1.2.
* **Nothing is kept across a restart.** A restarted dashboard shows "no
  data" until its first answers, so no value outlives the run that
  fetched it.
* **The dashboard draws; the source owns no window.** `erx_quotes` sends
  the dashboard a board, and the dashboard's view draws it with the clock
  and the date.
* **The basic kiosk is unchanged by any of this.** Sample quotes, the
  clock and the date work with no network, no table and no trust store.

## Context

### What the sources offer

The endpoints were read with live requests from a development host, and
their documentation pages where they have them. None needs a key or an
account. The terms of use of Kraken, Coinbase and Cboe were not read:
the pages named for them returned errors to the fetcher or were not
found, so whether automated access and public display are allowed is
**unverified** for each. FRED's are below. [Terms](#terms-of-the-sources)
says why that is accepted.

| Source | Request | Price | Change | Freshness | Trust anchor |
| --- | --- | --- | --- | --- | --- |
| Kraken public REST (`docs.kraken.com`, "Get Ticker Information") | `GET https://api.kraken.com/0/public/Ticker?pair=XBTUSD` (and `ETHUSD`); the answer is `{"error":[],"result":{"XXBTZUSD":{...}}}` | `result.XXBTZUSD.c[0]`, the last trade's price, a decimal string | against `o`, the day's opening price at 00:00 UTC, a decimal string | the last trade | GTS Root R4, cross-signed by GlobalSign Root CA |
| Coinbase Exchange public REST (`docs.cdp.coinbase.com`, Exchange: market data is public) | `GET https://api.exchange.coinbase.com/products/BTC-USD/ticker` (and `ETH-USD`) | `price`, a decimal string | none in this answer | the last trade | GTS Root R4, cross-signed by GlobalSign Root CA |
| Cboe delayed quotes (the JSON behind cboe.com's quote page; undocumented) | `GET https://cdn.cboe.com/api/global/delayed_quotes/quotes/_SPX.json`, answered first with a 307 redirect | `data.current_price`, a JSON number | `data.price_change_percent`, a JSON number | delayed, typically 15 minutes (unverified) | ISRG Root X1, through ISRG Root X2 |
| FRED, series SP500 (`fred.stlouisfed.org`) | `GET https://fred.stlouisfed.org/graph/fredgraph.csv?id=SP500`, CSV with the header `observation_date,SP500` | the second column of the last row that has a value | none | the day's close | DigiCert Global Root G3 |

FRED's own API needs a key; the graph CSV does not. FRED's series page
carries S&P Dow Jones Indices' copyright and a restriction on
reproducing the index without its permission, and FRED's legal page asks
anyone using a third party's series beyond personal use to obtain the
owner's permission. So no S&P 500 source is both keyless and clearly
licensed for public display.

#### Terms of the sources

The kiosk is a demo, not a public service of record, so the sources'
terms are accepted as they stand and no source is dropped for them. The
table holds Kraken's and Coinbase's rows for the crypto quotes and both
S&P 500 rows, Cboe's delayed JSON first and FRED's daily close as its
fallback, each labelled with its credit and note. A deployment that is a
public service of record would read each source's terms first.

Three others were looked at and left out: CoinGecko's keyless endpoint
works, but its terms require a "Powered by CoinGecko" credit and forbid
storing or redistributing its data (clauses 4.3, 4.1.6 and 6.2 of
`coingecko.com/en/api_terms`); Yahoo's chart endpoint works, but its
terms bar automated collection (2(d)(ix)); Stooq's CSV now answers with a
JavaScript proof-of-work page.

Every source negotiated TLS 1.3 with an ECDSA P-256 leaf certificate of
about 90 days, so the trust store holds roots, never leaves
([design-crypto.md](design-crypto.md#the-trust-store)).

### What exists

* **The HTTPS client** of [design-crypto.md](design-crypto.md#https-clients):
  `ssl`, `public_key`, `crypto`, `asn1` and `inets` in the `app` release,
  `public_key:cacerts_get/0` reading the image's trust store, and
  `httpc` with `max_body_size` bounding every body.
* **The dashboard and its seam** (`examples/dashboard`):
  `erx_dashboard` starts the source its `source` value names with
  `start_link/1` and shows the last `{erx_dashboard_board, Board}` the
  source sent; `erx_dashboard_source` defines the board; the default
  source, `erx_dashboard_sample`, is the basic kiosk's.
* **Apps** of [design-packaging.md](design-packaging.md): the
  declaration, the `apps` row whose `services` are `display data net` on
  both development boards, `erx_app` starting the declared applications
  with their dependencies, the package's files at `/app`, `/app/share`
  for its data.
* **The network** of [design-network-stack.md](design-network-stack.md#the-grant):
  the app's session holds a `net` grant, `gen_tcp` and `gen_udp` run over
  it through `erx_net_client`, and `inet_res` resolves names over the
  grant's name servers.
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
  jitter, while every source of a quote fails.
* **Q-R5.** Every response is untrusted: its size is bounded before it is
  read, it is parsed by total functions with a fuzz target, and a
  malformed one is a reason, never a crash or a value.
* **Q-R6.** Changing a source, adding one or reordering a quote's sources
  changes the package's table, not the code.
* **Q-R7.** The full kiosk is tested end to end without the internet.
* **Q-R8.** The basic kiosk needs no network, no table and no `ssl` or
  `inets`: the live quotes are reached only by naming `erx_quotes` as the
  dashboard's `source`.

## The construction

The live source is a pure core and one effect process. `erx_quotes` is a
quotes source of the dashboard's seam `erx_dashboard_source`: the
dashboard's process starts the module the application's `source` value
names with `start_link/1`, and `erx_quotes` sends it
`{erx_dashboard_board, Board}` whenever the board changes. The dashboard
draws the window; `erx_quotes` owns none.

```text
  erx_quotes (effect process)                         pure modules
  ---------------------------                         ------------
  file:consult(quotes_table) ----------------------> erx_quotes_config: validate
  1 s tick, httpc answers, the wall clock ---------> erx_quotes_core: state, rounds,
                                                       backoff, staleness
  httpc:request(get, ...) <------------------------- actions: fetch, render
  httpc's answer ----------------------------------> erx_quotes_http: status, redirect,
                                                       Retry-After, error -> reason
  the body ----------------------------------------> erx_quotes_extract: body -> value
  {erx_dashboard_board, Board} to the dashboard <--- erx_quotes_view: model -> board
```

* `erx_quotes_core:tick(State, Now, Jitter)` and
  `erx_quotes_core:outcome(State, Quote, Outcome, Now, Jitter)` return the
  next state and a list of actions, `{fetch, Quote, Source, Url}` and
  `render`. `Now` is monotonic milliseconds and `Jitter` a number in
  `[0.8, 1.2)` the effect process draws with `rand`, so the core reads no
  clock and no generator and is tested with exact values. `render` makes
  the effect process compute the board and send it to the dashboard when
  it differs from the last one it sent.
* `erx_quotes_view:board(State, Now)` is the board the dashboard draws:
  the credit and one quote per row of the table. It is computed from the
  pairs and reasons alone, so the rule of Q-R1 and Q-R2 is in one
  function, `erx_quotes_view:status/4`.
* **At start** `erx_quotes` reads and validates the table, starts `ssl`
  and `inets` itself (`application:ensure_all_started/1`), starts the core
  with every quote due and ticks it every second. The basic kiosk never
  starts it, so its release needs neither application.

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

The table is a file of Erlang terms that `file:consult/1` reads, at the
path of the application's `quotes_table` value, by default
`/app/share/quotes.config`. The development table is
`examples/dashboard/live/quotes.config`, outside `share/` so that the
basic kiosk's package does not carry it; the full kiosk's package carries
it as `share/quotes.config`. `erx_quotes_config:validate/1` checks the
whole table before `erx_quotes` starts anything, and a table it refuses
stops the dashboard's start with the reason, so the session ends with it,
which `/proc/apps` shows. The table is the app's own file, inside its
package, which the session mounted against the root hash the system
domain authenticated ([design-packaging.md](design-packaging.md#an-apps-session)).

```erlang
{quote, btc, #{label => <<"BTC/USD">>, decimals => 2, period => 10,
               sources => [kraken_btc, coinbase_btc]}}.
{quote, eth, #{label => <<"ETH/USD">>, decimals => 2, period => 10,
               sources => [kraken_eth, coinbase_eth]}}.
{quote, spx, #{label => <<"S&P 500">>, decimals => 2, period => 60,
               sources => [cboe_spx, fred_spx]}}.

{source, kraken_btc,
 #{url => <<"https://api.kraken.com/0/public/Ticker?pair=XBTUSD">>,
   format => json,
   price => [<<"result">>, <<"XXBTZUSD">>, <<"c">>, 0],
   change => {from, [<<"result">>, <<"XXBTZUSD">>, <<"o">>]},
   credit => <<"Kraken">>, note => <<"change since 00:00 UTC">>}}.
{source, coinbase_btc,
 #{url => <<"https://api.exchange.coinbase.com/products/BTC-USD/ticker">>,
   format => json, price => [<<"price">>], change => none,
   credit => <<"Coinbase">>}}.
{source, cboe_spx,
 #{url => <<"https://cdn.cboe.com/api/global/delayed_quotes/quotes/_SPX.json">>,
   format => json, price => [<<"data">>, <<"current_price">>],
   change => {percent, [<<"data">>, <<"price_change_percent">>]},
   credit => <<"Cboe">>, note => <<"delayed">>}}.
{source, fred_spx,
 #{url => <<"https://fred.stlouisfed.org/graph/fredgraph.csv?id=SP500">>,
   format => {csv, 2}, change => none,
   credit => <<"FRED">>, note => <<"daily close">>}}.
```

`kraken_eth` and `coinbase_eth` are the same rows with `ETHUSD`,
`XETHZUSD` and `ETH-USD`. The full kiosk's table holds both S&P 500 rows, Cboe first and FRED as
its fallback ([Terms of the sources](#terms-of-the-sources)).

| Field | Meaning | Bound |
| --- | --- | --- |
| `quote` name | an atom naming the quote | at most 8 quotes |
| `label` | the quote's name on the screen | 1 to 32 bytes of printable ASCII |
| `decimals` | digits after the point | 0 to 8 |
| `period` | seconds between rounds while a source answers | 5 to 86,400 |
| `sources` | source names, tried in order | 1 to 4, each a `source` row, none twice |
| `source` name | an atom naming the source | at most 16 sources, each used by some quote |
| `url` | the request | `https`, a host, at most 512 bytes, as `uri_string:parse/1` reads it |
| `format` | `json`, or `{csv, Column}` | `Column` 1 to 16 |
| `price` | for `json`, the path to the price: binaries are object keys, integers array indexes from 0 | 1 to 8 steps; absent for `csv` |
| `change` | `none`; `{from, Path}`, the percentage from the value at `Path` to the price; `{percent, Path}`, a percentage the answer gives | `Path` as `price`; `csv` takes only `none` |
| `credit` | the source's name on the screen | 1 to 32 bytes of printable ASCII |
| `note` | what the value is, beside the credit | 0 to 48 bytes of printable ASCII; default none |

A table that breaks any bound, names an unknown field, or leaves a field
out that has no default, is refused whole, with the row and field named.
Validation turns `period` into milliseconds, so every time the core
holds or compares, `Now` included, is in milliseconds.

### A quote's state

```erlang
-type quote() :: #{value    := none | {Price :: float(), Change :: none | float(),
                                       Source :: atom(), FetchedAt :: integer()},
                   failure  := none | {Reason :: reason(), At :: integer()},
                   failed_rounds := non_neg_integer(),
                   next_at  := integer(),
                   trying   := none | {Index :: pos_integer(), FirstReason :: none | reason()}}.
-type source() :: #{not_before := integer(), held := none | reason()}.
```

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

`erx_quotes` makes each request with

```erlang
httpc:request(get, {Url, [{"user-agent", "erxos-quotes/1"}]},
              [{timeout, 20000}, {connect_timeout, 10000},
               {autoredirect, false}, {autoretry, 0}],
              [{sync, false}, {receiver, self()}, {body_format, binary},
               {max_header_size, 10240}, {max_body_size, 65536}])
```

and no `ssl` option, so `httpc` takes the system's TLS defaults
([design-crypto.md](design-crypto.md#https-clients)). The two limits are
options of the fourth argument, where `httpc` reads them; `inets`' edit
makes them bound the response's head and body in every framing
([design-crypto.md](design-crypto.md#otps-applications)). `autoretry` is
0, so `httpc` never repeats a request on a `Retry-After` of its own
accord and the core alone decides when a source is asked again. The
answer reaches the process as `{http, {RequestId, Result}}`, and
`erx_quotes_http:classify(Result, Url, Hops, WallSeconds)` turns it into
one of, where `WallSeconds` is the wall clock, `os:system_time(second)`:

* **`{body, Bytes}`** for status 200 with a binary body; a 200 whose body
  is not a binary is `failed`;
* **`{follow, Url2}`** for status 301, 302, 303, 307 or 308 with one
  `location` header whose value, resolved against `Url` with
  `uri_string:resolve/2`, has the scheme, host and port of `Url`, while
  `Hops` is below 3; the effect process asks `Url2` within the same
  round. A `location` of bytes outside printable ASCII is refused as
  `redirect` before `uri_string` parses it, since `uri_string` raises on
  some non-ASCII bytes. So every request goes to the origin the table names, the
  server's certificate is checked against that host, and the credit the
  screen shows stays true. Whether Cboe's first answer, a 307, stays
  within its origin was not seen (unverified); if it does not, the table
  names the URL it leads to;
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
15 minutes while its sources fail, no round starts while every source of
the quote is held back, a server's `Retry-After` holds back that source
alone, for up to an hour, while the quote's other sources serve, and
quotes that failed together do not retry together.
At most one request per quote is in flight, so `erx_quotes` has at most 8
requests open at once.

### Reading a body

`erx_quotes_extract` is the one reader of response bytes. Its input is
at most 65,536 bytes, the bound `httpc` enforced.

* **`json`**: `json:decode/1` of OTP's `stdlib`, which keeps its own stack
  rather than recursing, so nesting costs heap within the input's size
  (`json.erl:838`, `:881`); object keys stay binaries, so no atom is made.
  The path is walked step by step: a binary step needs an object holding
  that key, an integer step a list long enough. A decode error or a step
  that does not match is `bad_data`.
* **`{csv, Column}`**: the body is split into lines at `\n`, a trailing
  `\r` dropped; the first line is the header; the value is `Column` of
  the last line whose field there is a decimal.
* **A price** is a JSON number, or a decimal string of at most 32 bytes in
  the grammar `-?[0-9]{1,15}(\.[0-9]{1,12})?`, converted to a float. It
  must be above 0 and below 10^15. A change's reference value is checked
  the same way; a given percentage must lie in `[-100, 1000]`.

One failure path: every check throws, and `value/2` catches once and
answers `{error, bad_data}`.

### What the screen shows

The dashboard's quotes panel, under its header, which carries the board's
credit, `Live quotes`, lists one row per quote in the table's order. Each
row has the quote's label, its price with `decimals` digits, its change
with a sign and two digits, and a status line that the dashboard shows
under the label in place of the quote's symbol, as the board's quote
carries it (`status` in `erx_dashboard_source`):

| State | Status line |
| --- | --- |
| no value, no failure | `waiting` |
| no value, a failure | `no data: REASON` |
| a value, age at most `3 * period` | `CREDIT[, NOTE] - AGE`, and `: REASON` when the last round failed |
| a value, older | `stale, AGE - CREDIT[, NOTE]`, and `: REASON` when the last round failed |

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
  last board it sent and the table of requests in flight by `RequestId`.
  An answer whose `RequestId` it does not hold is dropped, so an answer
  that arrives after a restart changes nothing.
* **`erx_quotes` is linked to the dashboard's process**, as the seam
  `erx_dashboard_source` says, so the two restart together under the
  dashboard's supervisor. A restart reads the table again and puts every
  quote back at `waiting`; requests in flight are abandoned to `httpc`'s
  timeout, and the dashboard shows no board until the first one arrives.
  Repeated crashes reach the supervisor's intensity, which ends the app,
  and its start row's keeper starts the session again within its own
  intensity ([design-packaging.md](design-packaging.md#starting-an-app)).
* **A refused table or an application that does not start** stops
  `erx_quotes` with the reason, and the dashboard's start with it, so the
  session ends with the reason, which `/proc/apps` shows.
* **`httpc`'s processes** run under `inets`'s supervisor; a handler that
  crashes answers its request with an error, which is a failed source.
* **The network domain's restart** ends the grant; connections fail with
  their reasons until the domain service grants the session again
  ([design-network-stack.md](design-network-stack.md#the-grant)), and the
  next round uses the new grant.
* **Memory** is bounded by the table's bounds and the body limit: at most
  8 bodies of 64 KiB and their decoded terms at once.

## Refusals and error results

| Reason | Shown as | Comes from |
| --- | --- | --- |
| `no_net` | `no network` | `{error, eacces}` from a socket call: the session holds no `net` grant |
| `dns` | `name not found` | `nxdomain`, or no name servers in the grant's answer |
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
`boot`; on Fiasco, and on a Raspberry Pi 4 without a clock module,
every boot starts at 1970-01-01 and stays `unset` until something sets
it ([design-crypto.md](design-crypto.md#time)). Validation compares
each certificate's dates with the wall clock; an unset clock reads 1970
plus the uptime, before the validity of every certificate a public
authority issues, so `ssl` refuses the sources' chains with
`certificate_expired` (`pubkey_cert.erl:155-166`) and the screen shows
nothing it fetched. `erx_quotes` passes the wall clock,
`os:system_time(second)`, as the fourth argument of `classify`, and the classifier turns
`certificate_expired` into `clock_unset` when it reads before
2000-01-01, a time no set clock on a machine erXos runs on shows. Every
other certificate reason, `unknown_ca` among them, stays `certificate`,
since the clock does not decide it.

## Security

* **What the full kiosk can reach** is what its `net` grant reaches: every
  address the network stack routes to, this machine's own listeners
  included, and ports above 1,023 to listen on
  ([design-crypto.md](design-crypto.md#security)). `erx_quotes` asks only the
  origins of its table: it follows no redirect out of the origin it
  asked, so no source can send it to another host, this machine's
  listeners included.
* **What it trusts** is the image's trust store, read-only to every
  domain, and its own package. A source, a DNS answer or anyone on the
  path can withhold an answer, which shows as a reason; none can make
  the screen show a number that did not come over a connection whose
  certificate the trust store vouches for and whose name is the host of
  the table's URL, which is also the host every redirect stays on.
* **The basic kiosk reaches nothing.** It holds no `net` grant, starts no
  `ssl` or `inets`, and carries no table.
* **Plain HTTP is unreachable.** The table refuses an `http` URL and the
  classifier a redirect to one, and `autoredirect` is off, so no value
  arrives over an unauthenticated connection.
* **A hostile source** can make `httpc` hold at most 64 KiB of body and
  10 KiB and one read of head per request, in any framing, at most 8
  requests at once, and make `erx_quotes` parse
  them; it cannot make the dashboard crash, allocate past those bounds, create
  an atom, or put text on the screen.
* **Text.** The screen's texts are the table's, the kiosk's own words and
  numbers it formats; the renderer escapes every text property anyway
  (G5). Log lines go through the log service's escaping.

## Verification and testing

The host tests run under stock OTP 29.1.2 with nothing but the SDK on
their paths, as the landing gate runs every example's
([design-packaging.md](design-packaging.md#examples)), through
`test/host/erx_quotes_test.rb`. The EUnit suites
`erx_quotes_config_tests`, `erx_quotes_http_tests`,
`erx_quotes_extract_tests`, `erx_quotes_core_tests` and
`erx_quotes_fetch_tests` are in
`examples/dashboard/lib/erx_dashboard/test/`, beside `erx_quotes_fuzz`.
Each test below names the seeded failure that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| table (`erx_quotes_config_tests`) | the development table, `live/quotes.config`, validates; one table per bound, one past its edge, is refused with that row and field named; an `http` URL is refused | accepting `period` 4 passes the one-past-the-edge table |
| rounds (`erx_quotes_core_tests`) | a first source's failure asks the second at once; a second success shows the second's credit; the next round starts at the first; every source failing sets `failure` to the first's reason | starting the next round at the source that last answered fails the third case |
| held-back sources (`erx_quotes_core_tests`) | the first source answering 429 with `RetryAfter` 3,600,000 ms while the second answers: the next rounds ask only the second until an hour has passed, then the first again; both held back: no request until the earlier `not_before` | keeping `not_before` per quote instead of per source asks the first source ten seconds later |
| backoff (`erx_quotes_core_tests`) | waits in milliseconds for periods of 10,000 and 60,000 over eight failed rounds with `Jitter` 1.0 are exact, capped at 900,000; a success resets the count | dropping the cap gives 2,560,000 at the eighth round |
| staleness and ages (`erx_quotes_core_tests`) | a value shows fresh at `3 * period` after its fetch and stale 1 ms later; a failed round while the value is fresh shows its reason beside the fresh value; ages format at 119 s, 120 s, 7,199 s, 7,200 s and two days | comparing `>=` instead of `>` shows the value stale at exactly `3 * period` |
| no fabrication (`erx_quotes_core_tests`) | over generated event sequences, every price the board carries is the price of some successful outcome for that quote, with that outcome's credit and an age equal to `Now` minus its time | keeping the previous price on a failed round with a new `FetchedAt` breaks the age property |
| classify (`erx_quotes_http_tests`) | each status, redirect and error shape of the reasons table, built as `httpc` and `ssl` answer, maps to its reason; redirects to `http:`, to another host and to another port of the same host are `redirect`; a relative one is followed; a `location` of non-ASCII bytes is `redirect`; a fourth hop is `redirect`; a 200 whose body is not a binary is `failed`; `retry-after` of 0, 1, 3,600, 7,200, 11 digits and a date give none, 1,000, 3,600,000, 3,600,000, none and none; `certificate_expired` with the wall clock at 1970-01-01T00:05 is `clock_unset`, with it in 2026 `certificate`, and `unknown_ca` at 1970 `certificate` | following a redirect without comparing its host turns the other-host case into `follow` |
| extract (`erx_quotes_extract_tests`) | bodies in the shape of each source of [What the sources offer](#what-the-sources-offer), generated by the test, give the price and change they carry; a missing key, a wrong type, a 33-byte decimal, `0`, a negative price and a CSV whose last line has `.` give `bad_data` or the previous line as the rule says | taking the CSV's last line whatever its field turns the `.` case into `bad_data` |
| frame | `erx_ui_host` with the Erlang renderer draws the dashboard's tree for a fixed time and a fixed live board, one quote of each row of the screen table, `clock not set` among them, equal to the reference picture `dashboard-live` under `test/display/reference/` | showing a stale value without `stale` changes the frame |
| HTTPS on the host (`erx_quotes_fetch_tests`) | `erx_quotes`, the effect process, with `public_key`'s `cacerts_path` naming a test root (stock OTP's override, `pubkey_os_cacerts.erl:46`), fetches from an `ssl` server the test runs on the host's loopback with a ECDSA P-256 chain from `public_key:pkix_test_data/1` for `localhost`, with the request expression of [One request](#one-request) unchanged, and shows its value | the server's certificate made for `other.test` shows `certificate rejected`; a 70,000-byte body with its `content-length` shows `answer too big`, and with `max_body_size` moved into the third argument is taken whole |

**The fuzz target.** `erx_quotes_fuzz`, in
`examples/dashboard/lib/erx_dashboard/test/`, is run by
`tools/fuzz/erx_quotes.rb` from `tools/erx check-fuzz`, at a small budget
at the landing gate and at its configured one by `make check-fuzz`. It
covers the three readers of untrusted input of this document:

* **extract:** `erx_quotes_extract:value/2` over bodies of up to 64 KiB
  for each source of the development table: random bytes; generated
  answers of each shape with one field mutated, truncated or moved to a
  bound; nesting 10,000 deep; numbers with 400 digits or exponents of
  `e400`; CSV with no newline, with only a header and with `\r` alone.
  Properties: nothing raises; every accepted price is finite, above 0 and
  below 10^15; an unmutated generated answer gives the price it was built
  with. *Seeded failure:* accepting a JSON number without the bound check
  lets `1.0e300` through and fails the bounds property.
* **classify:** `erx_quotes_http:classify/4` over arbitrary terms and
  header lists, redirects included. Property: it raises on nothing and
  answers one of its three shapes.
* **the table check:** `erx_quotes_config:validate/1` over mutated and
  random tables. Property: it raises on nothing and answers a table or a
  refusal.

**The QEMU cell**, `display_domain/quotes`, is part of the full kiosk's
fourth step of Track D ([plan.md](plan.md)). It needs the display and a
network device, which it asks for: the display suite's display with
the network device of `QemuPlan::Nic` on restricted user networking,
so nothing the guest sends leaves the host. Its image carries:

* `examples/dashboard` packed by the SDK as the full kiosk, with `source`
  set to `erx_quotes` and a test table whose sources are
  `https://quotes.NIC_DOMAIN:8443/btc` and the like, enabled at boot;
* a second test app, `quotes_fixture`, needing `net`, whose OTP
  application listens with `ssl` on port 8443 of the guest's address and
  answers each path with canned bodies in the sources' shapes, from a
  certificate and key in its package, and after its first five answers
  for `/btc` answers 503;
* a trust store with the fixture's root added to the image's
  ([design-crypto.md](design-crypto.md#the-trust-store));
* a network configured `static` at the guest's address with the
  harness's name server as its one name server
  ([design-network-stack.md](design-network-stack.md#addresses-and-routes)),
  which answers `quotes.NIC_DOMAIN` with the guest's address.

The fixture's chain is made on the host by the stock oracle's
`public_key:pkix_test_data/1` with a validity from 1970 to 2099, so it is
valid on Fiasco's unset clock as on a set one; this is a property
of the test's certificate, not of the clock, and the cell's third case
below shows an ordinary certificate refused. The fixture runs in
the guest rather than on the host because slirp's TCP guest forward
carries every guest connection to its address over one stream to the
host (`tools/lib/erx/net_device_echo_server.rb`), which cannot carry
separate TLS connections; the connection runs through the stack's
loopback path, since the destination is the stack's own address.

`erx_quotes` writes one log line per change of a quote's state, naming the
state, the price shown and the source or the reason, as `quotes: btc
fresh 64412.50 kraken_btc` or `quotes: btc stale 64412.50 {status,503}`,
which the harness reads from the serial line. The cell
passes when every quote reaches `fresh` with the fixture's prices, and
`btc` turns `stale` after the fixture's 503s, still showing the price of
its last answer and `HTTP 503` as its reason. *Seeded
failures:* the image's trust store built without the fixture's root
makes every quote `no data: certificate rejected`, the `unknown_ca`
reason whatever the clock; the fixture answering `/eth` with a body of
70,000 bytes and no `content-length` makes `eth` `no data: answer too
big`, which only `httpc`'s erXos edit gives
([design-crypto.md](design-crypto.md#otps-applications)).

A third case runs the cell with the fixture's certificate for `/spx`
made with an ordinary validity, from the build's date to ten years
later, on a wall clock before 2000: the stopgap's unset clock, or on
erXos's kernel QEMU's real-time clock started at 1970 with `-rtc
base=1970-01-01` (unverified: QEMU's documentation was not read). It
passes when `spx` shows `no data: clock not set` while `btc` and `eth`
stay `fresh`. *Seeded failure:* the classifier's wall-clock test taken
out shows `certificate rejected`.

## Alternatives considered

* **A host-side fixture server through a guest forward.** Rejected for
  the cell: the forward carries every guest connection over one stream.
* **A separate quotes app.** Rejected: a second app would open its own
  window beside the dashboard's, or repeat the dashboard's window code.
  A quotes source of the dashboard's seam keeps one window, one clock
  and one view, and the basic kiosk is the same application with its
  default source.
* **The sources in code, one module per provider.** Rejected: each new
  provider would be code and a new reader; two formats and paths cover
  every source considered.
* **Showing the source's own timestamp.** Not adopted: the sources give
  times in different forms, some without a zone (Cboe's `timestamp`), and
  the age of the fetch is what `erx_quotes` knows for certain; the table's
  `note` says what the value is, `delayed` or `daily close`.
* **Keeping the last values across a restart** in the app's directory.
  Not adopted: it needs `data`, and a value read back after a restart has
  an age the session did not measure.
* **A per-source trust anchor in the table.** Not adopted: the system's
  store serves every app the same way, and the cell tests the store
  itself.

## Open decisions

1. **How the full kiosk's package sets `source` and asks for `net`.** The
   packaging mechanism for setting an application environment value in a
   package is not yet designed, and the basic kiosk's declaration asks
   for `display` alone. *Recommendation:* a full-kiosk declaration of the
   same application directory, `needs display net`, whose package carries
   `share/quotes.config` and sets `source` to `erx_quotes`; the basic
   kiosk's declaration and package stay as they are. The decision is
   taken with the packaging design, in the QEMU cell's step.

## References

* Kraken REST API, "Get Ticker Information",
  <https://docs.kraken.com/api/docs/rest-api/get-ticker-information>, and
  its rate limits guide.
* Coinbase Exchange API, <https://docs.cdp.coinbase.com/exchange/docs/welcome>.
* FRED API, "series/observations",
  <https://fred.stlouisfed.org/docs/api/fred/series_observations.html>;
  FRED legal notices, <https://fred.stlouisfed.org/legal/>.
* CoinGecko API terms, <https://www.coingecko.com/en/api_terms>.
* OTP 29.1.2 source archive, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`
  (the pin in `deps.lock`): `lib/inets/src/http_client/httpc.erl`,
  `httpc_handler.erl`; `lib/ssl/src/ssl.erl`, `ssl_handshake.erl`;
  `lib/public_key/src/pubkey_cert.erl`, `pubkey_os_cacerts.erl`;
  `lib/stdlib/src/json.erl`.
