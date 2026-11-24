# Logging in through a front end

A person reaches erXos from somewhere other than its console: an SSH
client, a browser, a phone on the Bluetooth console. In each case a
**front end**, a configured domain that parses what that medium sends,
asks the system domain to log the person in, and on success gets the
**line** of a new session of the person's principal and nothing else.
This document is the one interface every front end logs in through,
`login`, a facet of the system domain: its operations and bounds, who
holds it, what it trusts a front end for, how a passphrase is checked,
what a login returns and when a login ends.

What a front end does with its line is its own design: the SSH domain's
channels open ttys ([design-ssh.md](design-ssh.md)), the web domain opens
views ([design-web.md](design-web.md)), the Bluetooth console masters one
tty per phone ([design-bluetooth.md](design-bluetooth.md#the-console)).
Login at a display, with its prompt, lock and overlay, is
[design-display.md](design-display.md#risks-and-decisions)'s decision
14; a display login that needs a facet takes this one
([Risks and open decisions](#risks-and-open-decisions)). The console's
own lines, the UART and the host link, are the system domain's and call
the principal service directly ([design-live.md](design-live.md#the-console)).

## Context

* **Lines exist.** A session serves a line to a grantee the system domain
  names at run time, minted by `erx_domain:line(Name, Session, Peer,
  Opening)` (`erlang/apps/erx_domain/src/erx_domain.erl:271`), ending with
  the opening, a process of the system domain, and with the session
  ([design-system.md](design-system.md#a-sessions-lines)). The host link's
  `web` facet already opens root's line this way
  (`erlang/apps/erx_uart/src/erx_hostlink_web.erl:114`).
* **Sessions start from a principal's template** through
  `erx_domain:start_session/2` (`erx_domain.erl:127`) and end with
  `erx_domain:stop/2`.
* **A facet tells its service who called.** `erx_facet` hands its
  callback's `admit/3` the caller's pid after checking that the caller
  and its alias are both the grantee's (`erx:call_from/3`), and forwards
  to the service under a fresh alias of its own
  (`erlang/apps/erx/src/erx_facet.erl`, module documentation). So the
  service behind a facet sees the facet's forward, never the caller,
  unless the callback carries the caller into the forward, as
  `erx_session_line`'s `admit/3` does for every line.
* **The passphrase checker is the vault's**
  ([design-system.md](design-system.md#the-vault), "Logins"): it counts
  failures by name in two classes of terminal and by terminal, answers
  matched, did not match, `limited` or `unavailable`, and answers a
  stranger as it answers a wrong passphrase, after the same time. The
  vault is [plan.md](plan.md#m11-security-closure)'s.
* **What is built.** No login facet exists in the tree. SSH runs stage 1
  of [design-ssh.md](design-ssh.md#stages), `erx_ssh_dev` in root's own
  session with root's authority, and the web front end's login is
  designed but not built.

## Requirements

| Requirement | Consumer and what breaks without it |
| --- | --- |
| **L1.** One interface for every front end | the SSH domain, the web domain and the Bluetooth console; two copies of one check diverge |
| **L2.** A login gives its front end the session's line and nothing else | every front end parses hostile input; a facet that granted more would hand a parser defect authority over principals |
| **L3.** A login ends when the front end's connection ends | SSH, the web and the phone console; a crashed connection would otherwise leave a session running with nobody at its line |
| **L4.** A passphrase is checked in one place, under the network limits | every front end; a front end that checked passphrases itself, or under the console's local limits, would let a network peer guess faster or lock a name out at the UART |
| **L5.** No answer tells a principal from a stranger | every front end; names are enumerable otherwise |
| **L6.** What a front end can make the system domain keep or do is bounded and declared | the system domain, whose fault resets the machine |
| **L7.** No login reaches the system shell | the system shell opens only at a line the manifest marks secure ([design.md](design.md#decisions)) |

## Design

### A login belongs to the process that asked for it

The construction: **a login is owned by the front end's process that
called for it.** The login service keeps one table of logins, keyed by
that process, which it monitors. A row is the process's outstanding
cookie, its session, or both; the row goes when the process ends, and
its session with it. The facet's callback, `erx_login_facet`, carries
the caller's pid into every forward, as `erx_session_line`'s callback
does, and the facet behaviour has already checked that the pid is a
process of the grantee, so the key is a fact the front end cannot forge
for another domain's process.

Each requirement that would otherwise be a rule of its own follows:

* **The connection is the process.** SSH's key login binds a signature
  to the cookie of one connection's first exchange
  ([design-ssh.md](design-ssh.md#logging-in)); both the cookie and the
  login that uses it come from the connection's state machine process,
  which runs the exchange and authentication, so "the connection's
  cookie" is "the row of the calling process". No connection identifier
  crosses the facet, and none can name another connection's cookie.
* **L3 by construction.** A session started by a login ends when the
  process that logged in ends: a closed SSH connection, a crashed one, a
  phone that walks out of range, a browser login the web domain drops.
  The front end has no `logout` to remember: it ends a login by ending
  the process that holds it, so no code path of a front end can leave a
  session behind, and a front end that crashes ends every session its
  processes held. When the front end's facet ends, every row of that
  grant goes too.
* **One login per process.** A process holds at most one session; a
  second login from it is refused `badarg`. A front end that serves
  several people runs a process for each, as the SSH daemon does for
  each connection and the phone console does for each phone.
* **L6, a bound per grant.** Each grant's rows, cookies and sessions
  together, are at most its `logins` parameter; past it `cookie` and
  the logins answer `unavailable`. Each row costs the system domain a
  monitor and a few words, so the manifest's grants bound the table.
  Nothing evicts a row to make room: a row goes only with its process,
  its use or its cookie's grace.

### Who holds it

`login` is declared in `abi/services/login.txt`, served by the system
domain. A configured domain holds it by a facet row of the manifest
naming two parameters:

* `line`, the session line the login mints for this front end, one of
  the `served_by session` interfaces (`?ERX_LINES`): `tty_line` for a
  front end whose connections master ttys, `web_line` for the web
  domain;
* `logins`, the grant's bound on rows.

The row's operation list is the grant's methods, through the facet
behaviour's operation check: a front end calls only the operations its
row lists, and any other is refused `eperm` before the callback sees it
([design-domains.md](design-domains.md#facets)).

| Front end | `line` | operations | `logins` |
| --- | --- | --- | --- |
| the SSH domain ([design-ssh.md](design-ssh.md#the-ssh-domain)) | `tty_line` | `cookie`, `key_ok`, `login_key`, `login_passphrase` | 128, twice the daemon's 64 connections |
| the web domain ([design-web.md](design-web.md#logging-in-and-the-line)) | `web_line` | `login_passphrase` | 16, the front end's live logins |
| the phone console ([design-bluetooth.md](design-bluetooth.md#the-console)) | `tty_line` | `login_passphrase` | 8 |

The manifest check holds the facet to that table, as an allow-list: it
refuses a `login` row on any other domain, a row whose `line` or
operations differ from its holder's, and more than one row per holder.
`tty_line` is the session line [design-system.md](design-system.md#a-sessions-lines)
serves a front end whose connections master the session's ttys,
`open_tty` and, with design-ssh.md's answer on jobs, `open_job`;
design-ssh.md and design-system.md name it `ssh_line`, served by
`erx_ssh_line`, and package 2 of the [Build order](#build-order)
renames both, since the phone console masters ttys through it too. Whoever
masters a tty of a logged-in session can already type any command its
shell runs, so a front end that never opens a job gains nothing by being
refused one, and one line interface serves SSH and the phone console
alike.

### Operations

Every answer is one of the closed set below; the facet behaviour adds
`busy` past the grant's requests in flight and `eperm` for an operation
the row does not list.

| Operation | Checks | Answer |
| --- | --- | --- |
| `cookie()` | the caller has no session; draws 16 bytes from `erx_bytes:entropy/1` and keeps them in the caller's row for the login grace, 120 s, replacing the row's last | `{ok, Cookie}`, or `{error, unavailable}` when the generator fails or the grant's rows are full |
| `key_ok(User, KeyBlob)` | `User` names an enrolled principal whose login keys hold `KeyBlob` | `true` or `false`, the same for an unknown principal and an unknown key |
| `login_key(User, Exchange, Alg, KeyBlob, Sig, Peer)` | the caller's row holds an outstanding cookie and no session; the exchange, signed data and signature as [design-ssh.md](design-ssh.md#logging-in) gives them; a match retires the cookie | `{ok, Line}` or `{error, no_match \| limited \| unavailable \| badarg}` |
| `login_passphrase(User, Passphrase, Peer)` | the caller has no session; the passphrase checker of [The passphrase check](#the-passphrase-check), class `network`, terminal `Peer` | `{ok, Line}` or `{error, no_match \| limited \| unavailable \| badarg}` |

On a match the service starts a session of the principal from its
template (`erx_domain:start_session/2`) with the environment the front
end's line implies (`display` set to `web` for `web_line`), records it
in the caller's row, and has the session mint the grant's `line` for the
front end with the login facet as the opening (`erx_domain:line/4`). The
answer is the line's facet. A session start the principal's quota or
budget refuses answers `unavailable`, logged with its reason. A caller
that ends while its login is being checked or its session started leaves
no session: the service stops a session whose row has gone as soon as
the start returns.

Arguments are bounded where the facet decodes them, before any check:
`User` is 1 to 32 bytes of the principal-name alphabet, `Passphrase` 1 to
1,024 bytes, `Peer` at most 64 bytes, kept only for the terminal counter
and the log, through the log's escaping; SSH's blobs and exchange input
are `erx_ssh_wire`'s ([design-ssh.md](design-ssh.md#logging-in), S3).
Anything else is `badarg`. The largest request is a `login_key` with its
64 KiB exchange input, so the grant's `max_request` is 131,072, derived
as a line's is; `in_flight` is 8, each passphrase login waiting on the
checker's network queue.

`Peer` is the front end's word: an address, a bond's identity, a
browser's remote address. It names the terminal whose failures the
checker counts, so a lying front end moves only its own counters; the
per-name limit binds whatever it says.

**L5.** A name that is no principal's, an app's principal, which has no
credentials, and a principal that has not enrolled all answer
`no_match`, after the checker's time for a wrong passphrase. Enrolment
is at the UART alone.

**L7.** The answer is a session line and nothing else. Only the console
grants the system-shell facet, at a secure line, and no front end's line
is one.

### The passphrase check

The login service hands the name, the passphrase, the class `network`
and the terminal to the principal service, which passes them to its one
passphrase checker and gives back its answer. Every login facet is
`network`: none of its front ends is a terminal wired to the machine, so
no phone, browser or SSH client can lock a name out at the UART. The
checker is the vault ([design-system.md](design-system.md#the-vault)),
with its limits: 5 failures in 60 s per name in the network class, 5 per
terminal, one derivation at a time for the network class, each answer
after the login envelope. Until a checker exists, `login_passphrase`
answers `unavailable` and no front end logs anyone in by passphrase. What
checks passphrases in a development build before the vault is an open
decision ([Risks and open decisions](#risks-and-open-decisions), 1).

The front end sees the passphrase, as the SSH daemon does in
keyboard-interactive and the phone console does on the stream it
decrypts; it never stores, logs or echoes one, and the login service
keeps none past its call.

### The service and its facet

`erx_login`, a process of the system domain, owns the table. Its
decisions are a pure core, `erx_login_core`: the row states (none,
cookie, cookie and session, session) and their transitions on each
operation, a checker's answer, a session start's result, a cookie's
grace and the end of a process or a grant, each returning the next
table and the effects to carry out (start a session, mint a line, stop a
session, monitor or demonitor). The process carries the effects out.
`erx_login_facet` is the facet callback: `operation/1` maps a request to
its operation, and `admit/3` checks the arguments' bounds and forwards
`{Request, Caller, Grant}`, `Grant` holding the row's `line` and
`logins`, which the front end never supplies.

## Invariants

| Invariant | Holds because |
| --- | --- |
| **G1.** A cookie, a key login and a passphrase login act only on the calling process's row | the key is the caller the facet checked is the grantee's |
| **G2.** No session started by a login outlives the process that made it, or the login service | the row's monitor stops it; a start that finishes after the row went is stopped; the service links each session's domain process |
| **G3.** No grant holds more than `logins` rows | the core refuses past it; rows go only with their process, use or grace |
| **G4.** A login mints exactly its grant's `line` for its holder | the line comes from the grant the facet forwards, never from the request |
| **G5.** A passphrase is checked only by the principal service's checker, class `network` | the service has no other path; the class is fixed in the service |

## Failure handling

| Failure | Detected by | Effect | Recovery |
| --- | --- | --- | --- |
| a front end's connection process ends | the row's monitor | its cookie goes; its session stops; the line's facet and ttys end with the session | the person connects again |
| a front end's domain ends | the facet's grantee | the facet ends; every row of the grant goes, its sessions stopped | the manifest restarts the domain |
| the login service crashes | its supervisor in the system domain | every login facet ends with it, and every session it started ends, since the service links each session's domain process; the table is rebuilt empty | front ends reconnect; a lost cookie fails only the login in progress |
| the checker is unavailable | its answer | `unavailable` | the person tries later |
| a session start fails | `start_session/2`'s answer | `unavailable`, logged with its reason | none needed |

## Refusals and error results

| Answer | When |
| --- | --- |
| `no_match` | wrong passphrase, key or signature; unknown, app or unenrolled principal; no outstanding cookie for a key login |
| `limited` | the checker's per-name or per-terminal limit |
| `unavailable` | no checker, the checker failing, the grant's rows full, the generator failing, a session start refused |
| `badarg` | an argument out of bounds, or a caller that already holds a session |
| `busy` | the grant's `in_flight` requests outstanding (the facet behaviour) |
| `eperm` | an operation the grant's row does not list (the facet behaviour) |

## Security

* **What a compromised front end gains.** The facet, the lines its logins
  minted, and what it sees in clear: the passphrases and the sessions'
  traffic of the people using it while it runs. Without a principal's
  passphrase or private key it starts no session but through a person
  logging in; it guesses under the checker's network limits alone; it
  can never reach the system shell, another front end's rows or a line
  of another interface.
* **What the system domain parses.** The arguments above, each bounded in
  `admit/3` before the service sees it, and SSH's blobs through
  `erx_ssh_wire`, which has a fuzz target. The login service's request
  decoding is a parser of untrusted input and gets a fuzz target of its
  own, over `admit/3`'s bounds checks.
* **No answer tells who exists** (L5), and the class `network` keeps the
  UART's counters out of reach.

## Verification

Each passing case is paired with the seeded fault that proves the test
ran the code it names.

| Test | Passing case | Seeded fault the test must catch |
| --- | --- | --- |
| core, exhaustive (host) | every row state against every event gives the transition table above | a transition that keeps a session after its process's end |
| connection binding (host) | `login_key` from a process other than the cookie's answers `no_match` | the table keyed by the facet's forward instead of the caller |
| L3 (QEMU) | killing a front end's logged-in process ends its session domain within 5 s | the row's monitor dropped |
| late start (host) | a caller that ends during `start_session` leaves no session | the post-start check of the row removed |
| one login per process (host) | a second login from a process with a session answers `badarg` | the check removed: a second session starts |
| bound (host) | the `logins`th row is taken, the next answers `unavailable`, and a row freed by its process's end makes room | the bound compared with `>` |
| grant's methods (QEMU) | the phone console's grant calling `cookie` is refused `eperm` | the console's row listing every operation |
| grant's line (QEMU) | a web grant's login mints `web_line`, a console grant's `tty_line` | the line taken from the request |
| passphrase (QEMU, with a checker) | the right passphrase opens a session; a wrong one and an unknown name answer `no_match`; the sixth failure in 60 s answers `limited` | the checker's answer ignored, so a wrong passphrase opens a session |
| no checker (host) | `login_passphrase` answers `unavailable` | a missing checker read as a match |
| bounds and fuzz (host) | `admit/3` refuses each argument one past its bound; the fuzz target runs | one bound removed |
| manifest check (host) | a `login` row on another domain, with another `line`, or with another operation list is refused | the allow-list rule removed |

## Interfaces

| Interface | Between | Declared in |
| --- | --- | --- |
| `login`: `cookie`, `key_ok`, `login_key`, `login_passphrase`; parameters `line` and `logins` | each front end and the system domain | `abi/services/login.txt`, citing this document |
| `tty_line`: `open_tty`, later `open_job` | a front end and a session | `abi/services/tty_line.txt` ([design-system.md](design-system.md#a-sessions-lines)) |
| `web_line` | the web domain and a session | `abi/services/web.txt` |
| the principal service's passphrase check | the login service and the checker | internal to the system domain |

## Build order

Each package is one agent's, about 80 tool calls, ending in one reviewed
commit. Each runs the host tests of what it touches and the QEMU suite it
names; the full gates run once per batch.

1. **The login facet.** `abi/services/login.txt`; `erx_login_core` with
   its exhaustive host test; `erx_login` and `erx_login_facet` in the
   system domain; `login_passphrase` wired to the principal service,
   which answers `unavailable` while it has no checker; the session start
   and the line mint; the manifest check's allow-list; the fuzz target
   over `admit/3`; `abi/services/web.txt`'s comments pointed at the
   facet. A host front end stands in for a real one in the tests.
2. **`tty_line`.** `ssh_line` becomes `tty_line`, `erx_ssh_line`
   becomes `erx_tty_line`, and `abi/services/ssh.txt`'s line moves to
   `abi/services/tty_line.txt` with its limits under the new name, in the
   ABI, the code, the tests and the documents together.
3. **SSH's key login.** `cookie`, `key_ok` and `login_key` in the core and
   the service, `erx_ssh_wire` with its fuzz target, and the verifier's
   direct tests ([design-ssh.md](design-ssh.md#verification)).
4. **The SSH domain on the facet.** SSH stage 2's switch: `erx_ssh_keys`'
   hooks call the facet from the connection process, the login table
   holds each connection's line, and `erx_ssh_dev` goes
   ([design-ssh.md](design-ssh.md#stages)). SSH stage 2's other parts
   are its own packages.
5. **A passphrase checker**, by open decision 1: the vault's first form,
   or the development checker.
6. **The phone console**, with its manifest checks
   ([design-bluetooth.md](design-bluetooth.md#the-console)), placed by
   that document's open decision 4.
7. **The phone console's Bumble test**, pairing by passkey, logging in and
   running a command
   ([design-bluetooth.md](design-bluetooth.md#the-console)).
8. **The phone console on the Raspberry Pi 4**, the board's manual
   checklist.

Packages 1 and 2 are independent; 3 needs 1; 4 needs 2 and 3; 6 needs 1,
2 and Bluetooth stage 4 on QEMU; 7 needs 5 and 6; 8 needs 7 and
Bluetooth's Raspberry Pi 4 stage. The web domain's login moves onto the
facet with the web's network front end.

## Alternatives considered

* **Two facets, `erx_ssh_login` and `erx_web_login`, and a third for the
  phone.** Three copies of one table, one check and one rate limit; a
  fix to one misses the others.
* **A connection identifier in the request.** A front end could name any
  connection's cookie, and the service would have to bound and check a
  name the facet already gives it.
* **Keying by the facet's forward.** Each forward has a fresh alias, so
  a cookie taken in one call could never be found by the next.
* **`logout`.** It made ending a session the front end's duty on every
  path, a crash included, which it cannot keep; ending the process ends
  the login on every path.
* **The terminal class as a row parameter.** Every front end that holds
  the facet is a network one; a parameter with one allowed value is a
  rule nobody needs. A display login that needs the local class adds it
  with its design.

## Risks and open decisions

1. **Open: what checks a passphrase before the vault.** The phone console
   offers only passphrase logins, and the vault that checks them is
   M11's. Three ways:
   * wait for the vault, so the phone console works in a development
     build only from M11;
   * bring the vault's first form forward (one passphrase slot per
     principal, the `none` sealing backend, enrolment at the UART), which
     is the target design and so no throwaway work, but several packages
     of its own with Argon2id and the vault's file and storage;
   * a development checker: in a development build, the principal service
     checks root's passphrase against one line of a file on the record
     volume, read through the `login_keys` service as root's
     `authorized_keys` is ([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)),
     holding a salted hash written on the host, under the vault's counts
     and the same answer for a stranger, refused in every release build
     as the `record_volume` window is, and deleted with the record volume
     at the vault's stage. Its hash form is the package's choice; a
     crypt(3) SHA-512 string, which FreeBSD writes for `$6$`, is
     familiar, unverified against a source here. Its cost: a stopgap
     decoder with a fuzz target, and a hash anyone holding the card can
     try offline, as anyone holding it can read the card.

   Recommended: the development checker. It follows the precedent of
   root's login keys on the medium, takes one package, and lets the phone
   console and SSH's keyboard-interactive be tested before the vault;
   the vault replaces it behind the principal service's one check.
2. **Display logins.** Decision 14 of
   [design-display.md](design-display.md#risks-and-decisions) settles
   what shows the prompt and which domain sees the passphrase. If a
   display's front end is a domain other than the system domain, it holds
   this facet with the local class added as a parameter and its own
   line; if the prompt is the system domain's, it calls the principal
   service as the console's lines do and needs no facet.
3. **Keys open only to sessions that gave the passphrase.** A key login
   opens nothing in the vault and uses the principal's keys while another
   session holds them open ([design-ssh.md](design-ssh.md#logging-in)).
   A per-session unlock would be a field of the login's row and a vault
   record; it is an item of [todo-session.md](todo-session.md).
4. **Monitors and links the service relies on.** The table monitors
   processes of front-end domains, and the service links each session's
   domain process. Package 1 confirms on QEMU that such a monitor takes
   its `'DOWN'` when the process ends and when its domain ends, and that
   a session's domain process ends when the linked service does; where
   either fails, it says so before building on it.
