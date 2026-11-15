# The quotes kiosk: an app on the HTTPS client

`examples/quotes` is an app that shows the prices of Bitcoin, Ether and
the S&P 500 on a display, fetched over HTTPS from public endpoints that
need no key. It is built as a third party builds an app, through the SDK
alone ([design-packaging.md](design-packaging.md#examples)), and it is the
first consumer of the HTTPS client that
[design-crypto.md](design-crypto.md#https-clients) makes a capability of
every session and app: OTP's `ssl` and `httpc` over the `net` grant, with
the image's trust store. This document says what the app shows, where its
numbers come from, how it refreshes and backs off, how it shows data it
could not refresh, how it reads the responses, and how it is tested
without the internet.

**What it declares.**

```text
app quotes
  needs display net
  applications erx_quotes
```

The central construction is that **every number on the screen is a
value paired with the monotonic time it was fetched, or nothing, and the
screen is a pure function of those pairs, the current monotonic time and
the last failure of each quote.** A failure never replaces or alters a
value; it only adds a reason. So whether a value is fresh or stale, and
how old it is, follows from one subtraction, and no path can show a
value the app did not receive or hide how old it is.

Decisions every reader needs:

* **The sources are data.** Which endpoints the app asks, which field of
  each answer is the price, how the change is computed and what credit
  the screen gives are rows of `share/quotes.config` in the package. The
  code knows two body formats, JSON and CSV, and three change rules; a
  new source is a row, not code ([The source table](#the-source-table)).
* **Each quote has an ordered list of sources.** A round tries them in
  order until one gives a value; the screen names the source that did.
* **No byte of a response reaches the screen as text.** The app shows
  numbers it formats itself, the labels and credits of its own table,
  and fixed words for its reasons.
* **HTTPS only, validated as the system validates.** The table refuses a
  URL that is not `https`, the app follows a redirect only to an `https`
  URL, and it passes no TLS option, so every connection takes the
  defaults of [design-crypto.md](design-crypto.md#https-clients): the
  image's trust store, the server's host name checked, TLS 1.3 or 1.2.
* **Nothing is kept across a restart.** A restarted session shows "no
  data" until its first answers, so no value outlives the run that
  fetched it.

## Context

### What the sources offer

The endpoints were read with live requests from a development host, and
their documentation pages where they have them. None needs a key or an
account. The terms of use of Kraken, Coinbase and Cboe were not read:
the pages named for them returned errors to the fetcher or were not
found, so whether automated access and public display are allowed is
**unverified** for each. FRED's are below.

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
licensed for public display ([Open decisions](#open-decisions)).

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
* **Apps** of [design-packaging.md](design-packaging.md): the
  declaration, the `apps` row whose `services` are `display data net` on
  both development boards, `erx_app` starting the declared applications
  with their dependencies, the package's files at `/app`, `/app/share`
  for its data.
* **The network** of [design-network-stack.md](design-network-stack.md#the-grant):
  the app's session holds a `net` grant, `gen_tcp` and `gen_udp` run over
  it through `erx_net_client`, and `inet_res` resolves names over the
  grant's name servers.
* **The widget toolkit**: `erx_ui:open/1` and `erx_ui:tree/2`, the widget
  schema of `abi/formats/ui.txt`, whose kinds include `column`, `row` and
  `label`, and a renderer that escapes every text property it draws
  ([design-display.md](design-display.md), G5); `erx_ui_host` stands in
  for a display on the host.
* **The clock's state** at `/proc/time/status`, attribute `state`:
  `unset`, `boot` or `set` ([design-time.md](design-time.md#what-proc-shows)).

## Requirements

* **Q-R1.** Each quote shows the last value the app received for it,
  with the source that gave it and how long ago it was fetched, or that
  it has none.
* **Q-R2.** A value older than its quote's stale age is shown as stale,
  with its age, and never as current.
* **Q-R3.** When a quote cannot be refreshed, the screen says why, in one
  of a closed set of reasons, and says "clock not set" when certificate
  checks failed because the machine's clock was never set.
* **Q-R4.** The app asks each source at most once per its quote's period
  while the source answers, and backs off exponentially, with jitter and
  any `Retry-After` the source sends, while every source of a quote fails.
* **Q-R5.** Every response is untrusted: its size is bounded before it is
  read, it is parsed by total functions with a fuzz target, and a
  malformed one is a reason, never a crash or a value.
* **Q-R6.** Changing a source, adding one or reordering a quote's sources
  changes the package's table, not the code.
* **Q-R7.** The app is tested end to end without the internet.

## The construction

The app is a pure core and one effect process:

```text
  erx_quotes (effect process)                         pure modules
  ---------------------------                         ------------
  file:consult(/app/share/quotes.config) ----------> erx_quotes_config: validate
  1 s tick, httpc answers, /proc/time state -------> erx_quotes_core: state, rounds,
                                                       backoff, staleness
  httpc:request(get, ...) <------------------------- actions: fetch, render
  httpc's answer ----------------------------------> erx_quotes_http: status, redirect,
                                                       Retry-After, error -> reason
  the body ----------------------------------------> erx_quotes_extract: body -> value
  erx_ui:tree/2 <----------------------------------- erx_quotes_view: model -> widget tree
```

* `erx_quotes_core:tick(State, Now, Jitter)` and
  `erx_quotes_core:outcome(State, Quote, Outcome, Now, Jitter)` return the
  next state and a list of actions, `{fetch, Quote, Source, Url}` and
  `render`. `Now` is monotonic milliseconds and `Jitter` a number in
  `[0.8, 1.2)` the effect process draws with `rand`, so the core reads no
  clock and no generator and is tested with exact values.
* `erx_quotes_view:tree(State, Now)` is the widget tree. It is computed
  from the pairs and reasons alone, so the rule of Q-R1 and Q-R2 is in one
  function.

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

`share/quotes.config` holds Erlang terms that `file:consult/1` reads;
`erx_quotes_config:validate/1` checks the whole table before the app
starts anything, and a table it refuses ends the session with the
reason, which `/proc/apps` shows. The table is the app's own file, inside
its package, which the session mounted against the root hash the system
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
`XETHZUSD` and `ETH-USD`. Which S&P 500 rows the shipped table holds is
an [open decision](#open-decisions).

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

### A quote's state

```erlang
-type quote() :: #{value    := none | {Price :: float(), Change :: none | float(),
                                       Source :: atom(), FetchedAt :: integer()},
                   failure  := none | {Reason :: reason(), At :: integer()},
                   failed_rounds := non_neg_integer(),
                   next_at  := integer(),
                   trying   := none | {Index :: pos_integer(), FirstReason :: none | reason()}}.
```

`value` changes only on a successful outcome, which replaces it whole;
`failure` is set when a round ends with every source failed and cleared
when a round succeeds. `trying` is the round in flight: the index of the
source asked and the first source's reason, if it failed.

## Algorithms

### A round

A quote's round is due when `Now >= next_at` and no round of it is in
flight. The core asks its first source. On that source's outcome:

* **a value**: the round ends; `value` is the new pair, `failure` is
  cleared, `failed_rounds` is 0 and `next_at` is `Now + period`;
* **a reason**, with sources left: the core asks the next source at once,
  keeping the first source's reason;
* **a reason**, on the last source: the round ends failed; `failure` is
  the first source's reason, since the first source is the one the table
  prefers, `failed_rounds` grows by one, and `next_at` follows the
  backoff below.

A round always starts again at the first source, so a quote returns to
its preferred source as soon as that source answers again.

### One request

The effect process makes each request with

```erlang
httpc:request(get, {Url, [{"user-agent", "erxos-quotes/1"}]},
              [{timeout, 20000}, {connect_timeout, 10000}, {autoredirect, false},
               {max_body_size, 65536}],
              [{sync, false}, {receiver, self()}, {body_format, binary}])
```

and no `ssl` option, so `httpc` takes the system's TLS defaults
([design-crypto.md](design-crypto.md#https-clients)). The header limit is
`httpc`'s default, 10,240 bytes (`httpc.erl:431-441`). The answer reaches
the process as `{http, {RequestId, Result}}`, and
`erx_quotes_http:classify(Result, Url, Hops)` turns it into one of:

* **`{body, Bytes}`** for status 200;
* **`{follow, Url2}`** for status 301, 302, 303, 307 or 308 with one
  `location` header whose value, resolved against `Url` with
  `uri_string:resolve/2`, has the scheme `https` and a host, while `Hops`
  is below 3; the effect process asks `Url2` within the same round, as
  Cboe's first answer needs;
* **`{error, Reason, RetryAfter}`** for anything else, from the table of
  [Reasons](#refusals-and-error-results). `RetryAfter` is the
  `retry-after` header of a 429 or 503 answer when it is a decimal number
  of seconds from 1 to 3,600, and `none` otherwise.

A body goes to `erx_quotes_extract:value(Source, Bytes)`, which answers
`{ok, Price, Change}` or `{error, bad_data}`.

### Refresh and backoff

After a failed round,

```text
wait = min(period * 2^failed_rounds, 900 s) * Jitter
wait = min(max(wait, RetryAfter), 3600 s)        when the round saw a RetryAfter
next_at = Now + wait
```

So a quote with a period of 10 s waits about 20, 40, 80 s and so on to
15 minutes while its sources fail, a server's `Retry-After` is honoured
up to an hour, and quotes that failed together do not retry together.
At most one request per quote is in flight, so the app has at most 8
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
  the last line whose field there is a decimal. At most 100,000 lines are
  looked at.
* **A price** is a JSON number, or a decimal string of at most 32 bytes in
  the grammar `-?[0-9]{1,15}(\.[0-9]{1,12})?`, converted to a float. It
  must be above 0 and below 10^15. A change's reference value is checked
  the same way; a given percentage must lie in `[-100, 1000]`.

One failure path: every check throws, and `value/2` catches once and
answers `{error, bad_data}`.

### What the screen shows

The window is a `column` of one `row` per quote, in the table's order,
each with `label`s for the quote's label, its price with `decimals`
digits, its change with a sign and two digits, and a status line:

| State | Status line |
| --- | --- |
| no value, no failure | `waiting` |
| no value, a failure | `no data: REASON` |
| a value, age at most `3 * period` | `CREDIT[, NOTE] - AGE` |
| a value, older | `stale, AGE - CREDIT[, NOTE]`, and `: REASON` when the last round failed |

`AGE` is `N s` below two minutes, `N min` below two hours, `N h` below
two days and `N d` beyond, rounded down. A quote with no value shows
`--` for its price and change. `REASON` is the word of the
[reasons table](#refusals-and-error-results). The view sends a new tree
only when a text changed, which the toolkit diffs against the last one.

## Concurrency and failure

* **One process owns the state.** `erx_quotes`, under the app's
  supervisor, holds the core's state, the window and the table of
  requests in flight by `RequestId`. An answer whose `RequestId` it does
  not hold is dropped, so an answer that arrives after a restart changes
  nothing.
* **A crash of `erx_quotes`** restarts it with the table read again and
  every quote back at `waiting`; its requests in flight are abandoned to
  `httpc`'s timeout. Repeated crashes reach the supervisor's intensity,
  which ends the app, and its start row's keeper starts the session
  again within its own intensity ([design-packaging.md](design-packaging.md#starting-an-app)).
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
| `clock_unset` | `clock not set` | `certificate`, when `/proc/time/status` says `state unset` |
| `tls` | `TLS failed` | any other TLS alert |
| `{status, Code}` | `HTTP CODE` | a status other than 200 and the followed redirects |
| `redirect` | `bad redirect` | a redirect to a URL that is not `https`, one without a usable `location`, or a fourth hop |
| `too_big` | `answer too big` | `body_too_big` |
| `bad_data` | `bad answer` | the extractor's refusal |
| `failed` | `failed` | any answer the classifier does not recognise |

`httpc` reports a connection's failure as `{failed_connect,
[{to_address, Address}, {inet, Options, Reason}]}` (`httpc_handler.erl:784-790`),
and `ssl` an alert as `{tls_alert, {Alert, Description}}` (`ssl.erl:604`);
the classifier matches those shapes and maps an unknown one to `failed`,
so it never names a cause it did not see.

**The clock.** On erXos's kernel the clock is the real-time clock's
reading at boot when the machine has one, so QEMU `virt`'s boots at
`boot`; on the stopgap, and on a Raspberry Pi 4 without a clock module,
every boot starts at 1970-01-01 and stays `unset` until something sets
it ([design-crypto.md](design-crypto.md#time)). Against an unset clock
every certificate is outside its validity period and `ssl` refuses it
with `certificate_expired` (`pubkey_cert.erl:155-166`), so the app
fetches nothing it could show. When a round ends with `certificate`, the
effect process reads `/proc/time/status`, at most 4 KiB, and passes the
`state` attribute to the core, which shows `clock not set` for `unset`;
a missing file, a failed read or another value leaves the reason
`certificate`.

## Security

* **What the app can reach** is what its `net` grant reaches: every
  address the network stack routes to, this machine's own listeners
  included, and ports above 1,023 to listen on
  ([design-crypto.md](design-crypto.md#security)). It asks only the
  hosts of its table.
* **What it trusts** is the image's trust store, read-only to every
  domain, and its own package. A source, a DNS answer or anyone on the
  path can withhold an answer, which shows as a reason; none can make
  the screen show a number that did not come over a connection whose
  certificate the trust store vouches for and whose name matches the
  table's URL.
* **Plain HTTP is unreachable.** The table refuses an `http` URL and the
  classifier a redirect to one, and `autoredirect` is off, so no value
  arrives over an unauthenticated connection.
* **A hostile source** can send at most 64 KiB of body and 10 KiB of
  headers per request, at most 8 requests at once, and make the app parse
  them; it cannot make the app crash, allocate past those bounds, create
  an atom, or put text on the screen.
* **Text.** The screen's texts are the table's, the app's own words and
  numbers it formats; the renderer escapes every text property anyway
  (G5). Log lines go through the log service's escaping.

## Verification and testing

The host tests run under stock OTP 29.1.2 with nothing but the SDK on
their paths, as the landing gate runs every example's
([design-packaging.md](design-packaging.md#examples)). Each names the
seeded failure that proves it ran.

| Test | Passes when | Seeded failure |
| --- | --- | --- |
| table | the shipped table validates; one table per bound, one past its edge, is refused with that row and field named; an `http` URL is refused | accepting `period` 4 passes the one-past-the-edge table |
| rounds | a first source's failure asks the second at once; a second success shows the second's credit; the next round starts at the first; every source failing sets `failure` to the first's reason | starting the next round at the source that last answered fails the third case |
| backoff | waits for periods 10 and 60 over eight failed rounds with `Jitter` 1.0 are exact, capped at 900 s; `RetryAfter` 1800 gives 1800, 7200 gives 3600; a success resets the count | dropping the cap gives 2560 s at the eighth round |
| staleness and ages | a value shows fresh at `3 * period` ms after its fetch and stale 1 ms later; ages format at 119 s, 120 s, 7,199 s, 7,200 s and two days | comparing `>=` instead of `>` shows the value stale at exactly `3 * period` |
| no fabrication | over generated event sequences, every price the view shows is the price of some successful outcome for that quote, with that outcome's credit and an age equal to `Now` minus its time | keeping the previous price on a failed round with a new `FetchedAt` breaks the age property |
| classify | each status, redirect and error shape of the reasons table, built as `httpc` and `ssl` answer, maps to its reason; a redirect to `http:` is `redirect`; a fourth hop is `redirect` | following a redirect without checking its scheme turns the `http:` case into `follow` |
| extract | bodies in the shape of each source of [What the sources offer](#what-the-sources-offer), generated by the test, give the price and change they carry; a missing key, a wrong type, a 33-byte decimal, `0`, a negative price and a CSV whose last line has `.` give `bad_data` or the previous line as the rule says | taking the CSV's last line whatever its field turns the `.` case into `bad_data` |
| frame | `erx_ui_host` with the Erlang renderer draws a fixed state, one quote of each row of the screen table, `clock not set` among them, equal to `examples/quotes/test/reference/quotes` | showing a stale value without `stale` changes the frame |
| HTTPS on the host | the app's effect process, with `public_key`'s `cacerts_path` naming a test root (stock OTP's override, `pubkey_os_cacerts.erl:46`), fetches from an `ssl` server the test runs on the host's loopback with a chain from `public_key:pkix_test_data/1` for `localhost`, and shows its value | the server's certificate made for `other.test` shows `certificate rejected`; a 70,000-byte body with its `content-length` shows `answer too big` |

**The fuzz target.** `erx_quotes_extract_fuzz`, in the example's tests
and run by the landing gate at a small budget and by `make check-fuzz` at
its configured one, feeds `erx_quotes_extract:value/2` bodies of up to
64 KiB for each source of the shipped table: random bytes; generated
answers of each shape with one field mutated, truncated or moved to a
bound; nesting 10,000 deep; numbers with 400 digits or exponents of
`e400`; CSV with no newline, with only a header and with `\r` alone.
Properties: nothing raises; every accepted price is finite, above 0 and
below 10^15; an unmutated generated answer gives the price it was built
with. *Seeded failure:* accepting a JSON number without the bound check
lets `1.0e300` through and fails the bounds property.

**The QEMU cell**, `display_domain/quotes`, needs the display and a
network device, which it asks for: the display suite's display with
the network device of `QemuPlan::Nic` on restricted user networking,
so nothing the guest sends leaves the host. Its image carries:

* `examples/quotes` packed by the SDK with a test table whose sources are
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
valid on the stopgap's unset clock as on a set one. The fixture runs in
the guest rather than on the host because slirp's TCP guest forward
carries every guest connection to its address over one stream to the
host (`tools/lib/erx/net_device_echo_server.rb`), which cannot carry
separate TLS connections; the connection runs through the stack's
loopback path, since the destination is the stack's own address.

The kiosk writes one log line per change of a quote's state, naming the
state, the price shown and the source or the reason, as `quotes: btc
fresh 64412.50 kraken_btc` or `quotes: btc stale 64412.50 {status,503}`,
which the harness reads from the serial line. The cell
passes when every quote reaches `fresh` with the fixture's prices, and
`btc` turns `stale` after the fixture's 503s, still showing the price of
its last answer and `HTTP 503` as its reason. *Seeded
failures:* the image's trust store built without the fixture's root
makes every quote `no data: certificate rejected`; the fixture answering
`/eth` with a body of 70,000 bytes and no `content-length` makes `eth`
`no data: answer too big`, which only `httpc`'s erXos edit gives
([design-crypto.md](design-crypto.md#otps-applications)).

## Alternatives considered

* **A host-side fixture server through a guest forward.** Rejected for
  the cell: the forward carries every guest connection over one stream.
* **The sources in code, one module per provider.** Rejected: each new
  provider would be code and a new reader; two formats and paths cover
  every source considered.
* **Showing the source's own timestamp.** Not adopted: the sources give
  times in different forms, some without a zone (Cboe's `timestamp`), and
  the age of the fetch is what the app knows for certain; the table's
  `note` says what the value is, `delayed` or `daily close`.
* **Keeping the last values across a restart** in the app's directory.
  Not adopted: it needs `data`, and a value read back after a restart has
  an age the session did not measure.
* **A per-source trust anchor in the table.** Not adopted: the system's
  store serves every app the same way, and the cell tests the store
  itself.

## Open decisions

1. **The S&P 500 source.** No keyless source is clearly licensed for
   public display. The options: (a) Cboe's delayed JSON, the most
   current, undocumented and with terms unread; (b) FRED's daily close,
   documented, with S&P's copyright notice and FRED's ask for permission
   beyond personal use; (c) both, Cboe first and FRED as its fallback;
   (d) no S&P 500 row. *Recommendation:* (c) for the development
   example, each labelled with its credit and note, and before any image,
   recording or website shows the kiosk in public, read Cboe's and FRED's
   terms in a browser and drop the row if they forbid it.
2. **Publishing the crypto quotes.** Kraken's and Coinbase's terms for
   automated access and display were not readable by the fetcher.
   *Recommendation:* keep them as the table's sources and read both terms
   in a browser before a public showing, as for the S&P 500.

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
