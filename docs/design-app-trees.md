# An app's own tree: `/svc/NAME`

An app says what it has to say about itself, and takes the commands it
takes, in one file tree it serves. An administrator's session finds that
tree at `/svc/NAME`, NAME being the app's admitted name: a `status` file
to read, a `ctl` file for one-shot control when the app takes commands,
and any other read-only file the app sets. `/proc` keeps only what the
system itself observes, the start table's record of each app's run state
at `/proc/apps` among it.

This is the second of the three homes of
[CLAUDE.md](../CLAUDE.md) ("No new mechanism without a design that names
it"): "state the system observes (the kernel, the system services, a
configured domain, a runtime about its own processes) is an inspection
path declared in `abi/inspection.txt`, shown at `/proc`; what an app says
about itself, bytes someone keeps, or a thing someone commands is a file
tree its owner serves and the reader mounts, with a `status` file to read
and a `ctl` file for one-shot control". The decision row of
[design.md](design.md#decisions) states the same split.

## Context

### What exists

* **ntpd's state is an inspection kind.** `abi/inspection.txt` declares
  a kind `ntp` at the machine path `[ntp]`, reported by `runtime`, and
  ntpd's runtime collects it (`erlang/apps/erx/src/erx_ntp_records.erl`,
  which asks `erx_ntpd:status/1`). The inspector answers `[ntp]` in the
  system domain's own runtime, where no ntpd runs
  (`erlang/apps/erx/src/erx_inspector.erl`, `collect([ntp], _)`), so
  every attribute reads `unsupported` and `ntpctl -s` writes
  `ntpctl: /proc/ntp: unsupported`
  (`erlang/apps/erx_shell/src/erx_cmd_ntpctl.erl`, `no_value/1`).
  Routing the path to ntpd's session needs the inspector to find an
  app's domain and an agent bound that admits a machine path, which no
  design names. And `erx_ntpd:status/1` asks ntpd's main loop, which
  answers only while it waits, so a read during a resolution or an
  exchange times out.
* **Every other kind a runtime reports is about that runtime's own
  domain**: `domain`, `module` and `process`, at paths under a domain id
  or a process id. `ntp` is the one kind a runtime reports at a machine
  path.
* **The start table's record** is at `/proc/apps` and `/proc/apps/NAME`,
  reported by the start service and readable by an inspect facet whose
  session template holds `start`
  ([design-apps.md](design-apps.md#interfaces),
  [design-live.md](design-live.md#the-inspect-service)). It is what the
  system observes of an app: its row, its state, its reason, its domain.
* **Only configured domains serve facets.** A provider is the current
  incarnation of a configured domain, and its services are the ones the
  manifest's `service` rows declare for it
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)).
  A session serves nothing to another domain, and
  [design-apps.md](design-apps.md#requirements) keeps apps that serve
  facets out of scope.
* **A link is resolved in the reader's namespace.** A file server follows
  no link; the reader's resolver reads the link's text and goes on from
  its own `/` ([design-files.md](design-files.md#resolving-a-path)), and
  an open for writing follows a last link
  ([design-files.md](design-files.md#resolving-a-path), "The last
  name's link"). A tree an untrusted server serves can therefore hold
  `ctl -> /etc/start.conf`, and `echo x > /svc/app/ctl` in root's session
  would write root's own file.
* **A file call waits for its reply or its server's end.** An Erlang
  client's request waits for the reply or for the grant's end, and a
  process that ends with a request in flight needs no cleanup: its fids
  are clunked when its end reaches the grant
  ([design-files.md](design-files.md#fid-owners),
  [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).
  `flush` is no deadline: erXos's servers answer a flush only after the
  flushed request is settled
  ([design-files.md](design-files.md#flush)), so a hung server answers
  neither. A grant holds at most 64 requests in flight, and a request
  beyond that waits in the client or fails `emfile`
  ([design-files.md](design-files.md#bounds)).

### What FreeBSD does

FreeBSD releng/15.1 (References):

* `service NAME status` runs the script's `status` command, whose default
  prints `NAME is running as pid N.` or `NAME is not running.` and
  returns 1 (`libexec/rc/rc.subr`, `run_rc_command`, lines 1465-1474). A
  script adds its own words with `status_precmd` and `status_postcmd`, or
  replaces them with `status_cmd` (lines 1356-1359, 1178), and offers
  verbs of its own through `extra_commands` (lines 912, 1126). The run
  state is the system's, the rest the script's.
* A mount with `nosymfollow` follows no symbolic link: "Do not follow
  symlinks on the mounted file system. [...] You can still create or
  remove symlinks, or read the value of a symbolic link"
  (`sbin/mount/mount.8`, lines 272-277). `vfs_lookup` refuses to follow a
  link that lies on such a mount with `EACCES` (`sys/kern/vfs_lookup.c`,
  lines 1396-1414).

## Requirements

* **AT-R1.** `/proc` shows only what the system observes. No app's
  words appear there, and no app adds a kind to the inspection schema.
* **AT-R2.** Everything an app says about itself, and every command it
  takes, is in one tree it serves, at `/svc/NAME`.
* **AT-R3.** NAME is the app's admitted name. No app speaks under
  another's name, and no tree is reachable under a name the app chose.
* **AT-R4.** The manifest decides who reads and commands an app's tree;
  the app decides nothing about it.
* **AT-R5.** Nothing an app serves makes a reader act outside the tree,
  run code, or show a control character under the app's name.
* **AT-R6.** No system command waits on an app longer than a declared
  deadline, and a command cut off by it is reported as of unknown
  outcome and never repeated.
* **AT-R7.** After an app restarts, no reader reaches the old session's
  tree, and no descriptor opened on it reaches the new one.
* **AT-R8.** It feels like FreeBSD: `service NAME status` gives the run
  state, then the app's own words, as a script's `status_postcmd` does.

Outside this design: apps that serve facets to other apps; a native
app's tree (a declaration with `program` serves none); trees with
directories or writable files beyond `ctl`; and the app-side grammar of
any one app's commands, which is that app's design.

## Overview

```text
 app session ntpd_3 (principal ntpd)           root's session root_1 (template holds start)
 -----------------------------------           -------------------------------------------
 template declares `serves svc`                namespace: / ... /proc  /etc/start  /svc
 erx_svc (SDK): mint and erx_fs server                                              |
   status  <- erx_svc:set_status/1 from ntpd      `{facets, svc}`, nosymfollow ------+
   (ctl    <- erx_svc:set_ctl/1, if any)          /svc/ntpd -> registry {svc,<<"ntpd">>}
          |                                                         ^
          | ready report provides svc => erx_svc                     | installs facet
          v                                                         |
 system domain: domain service                                      |
   accepts: principal ntpd has a start row, template serves svc     |
   pairs: (newest live session of ntpd) x (each live session whose template holds start)
   introduces, asks erx_svc to mint, installs {Pid, rw} under {svc, <<"ntpd">>} ----+

 service ntpd status:  /proc/apps/ntpd (run state)  then  /svc/ntpd/status (ntpd's words)
                       through erx_svc_client, which ends its reader at svc_wait_max
```

**An app's tree, end to end.** ntpd's template declares that its
sessions serve `svc`. When the start service's keeper starts ntpd's
session, the session's runtime starts `erx_svc`, the SDK's tree server,
before its ready report, and the report names `erx_svc` as the mint of
`svc`. The domain service accepts it because ntpd is a principal with a
start row and its template declares `serves svc`, and from then on ntpd's
newest live session is the provider of the name `ntpd`. For every live
session whose template holds `start`, the domain service introduces the
two sessions, asks `erx_svc` for a facet bound to that session, and
installs it in the session's capability registry as `{svc, <<"ntpd">>}`
with rights `rw`. That session mounted one entry at `/svc` when it
started, a directory whose names are the `svc` facets its registry holds,
so `/svc/ntpd` appears. ntpd calls `erx_svc:set_status/1` after each
change; `erx_svc` keeps the rendered text and answers every read of
`status` from it, never from ntpd's own loop. `service ntpd status` reads
the run state from `/proc/apps/ntpd` and then `/svc/ntpd/status` through
`erx_svc_client`, which runs the read in a process it ends at
`svc_wait_max`. When ntpd's session ends, its facets end with it, so
`/svc/ntpd` leaves every registry; the next session provides again and
is granted anew.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **AT1.** `/proc` holds no app's words | a kind whose reporter is `runtime` is declared only at paths under a domain id or a process id, which the schema generator checks for every row of `abi/inspection.txt`, so a runtime can report only about its own domain, which [design-live.md](design-live.md#the-proc-tree) already enforces at the inspector ("What a runtime reports"); no other reporter is an app | a runtime-reported kind at a machine path, as `ntp` at `[ntp]` | the generator's check, with a seeded `kind` row reported by `runtime` at a machine path that fails the build |
| **AT2.** `/svc/NAME` is a tree of a session of principal NAME and of no other | the registry name `{svc, Name}` is set by the domain service from the providing session's principal, never from anything the session sends; a session provides `svc` only if its principal has a start row and its template declares `serves svc`; the provider of NAME is the newest live session of NAME that provides it; admitted names are unique ([design-packaging.md](design-packaging.md#admission), check 3) | a report whose `provides` names the tree's name; a provide accepted from a template without the declaration; an older session kept as provider beside a newer one | the domain service's host tests of the provider rule, each refusal seeded; the QEMU test below |
| **AT3.** No grant outlives its provider or reaches a later one | every `svc` facet is a process of the providing session's domain, minted there by `erx_svc`, so it ends with that session; the registry removes a facet at its end; a descriptor keeps the grant it was opened on, which answers `eio` once ended (F10) | a facet hosted outside the providing session, or a registry entry kept across the facet's end | the restart test of [Verification](#verification-and-testing) |
| **AT4.** No link in an app's tree is followed | the `/svc` entry carries `nosymfollow`, which the resolver honours for every link that lies in a tree the entry reaches; a bind or a program's table takes the flag of the entry its place lies on, and no mount or bind clears it, so following only narrows, as rights do; `erx_ns:mount/3` refuses a provider that names an `svc` facet, so `/svc` and its binds are the only entries by name that reach an app's tree; a mount of a grant's bare pid that a session's own code makes is its own choice, as a FreeBSD mount without `nosymfollow` is root's | a resolver that follows a link the entry refuses; a bind that drops the flag; a mount of an `svc` facet elsewhere | the link test and its seeded fault below; the resolver's fuzz target with entries carrying the flag |
| **AT5.** Nothing in an app's tree runs | every `svc` grant is `rw`, and no grant both writes and runs ([design-files.md](design-files.md#invariants), F6) | an `rx` grant of `svc` | the grant's rights test |
| **AT6.** No system command waits on an app beyond `svc_wait_max` | every system command reads and writes an app's tree only through `erx_svc_client`, which makes its call in a process it ends at the deadline; ending the process ends its fids ([design-files.md](design-files.md#fid-owners)) | a command that calls `file` on `/svc` in its own process | a chokepoint source check that only `erx_svc_client` names `/svc` among the shell's and the start service's modules, with a seeded direct read; the hung-server test |
| **AT7.** A line shown under an app's name holds no control | `service` and `ntpctl` show a status line only after `erx_svc_status:parse/1` accepts it, an identifier, a tab and a field the field escape writes, which holds no character the line escape changes ([design-live.md](design-live.md#attributed-text)); any other line shows as `[invalid]` | a reader that prints a line it did not parse, or unescapes a value for display | the parser's fuzz target and properties; the escape test below |
| **AT8.** Only sessions whose template holds `start` hold `svc` grants | the domain service derives the grantees from the manifest's `start` grants, and no manifest row grants `svc`; the system domain is never a grantee | a grant to every session; a manifest row granting `svc` | the domain service's host test; the manifest check refusing a facet row of `svc` |

## Data model

### The declaration

A session template declares that its sessions serve their tree with one
word, `serves svc`, in the manifest's source:

```text
session ntpd
  limits @limits.app
  runtime @artifact.emu
  release @artifact.ntpd
  serves svc
```

and a package declares the same in its `app.txt`
([design-packaging.md](design-packaging.md#the-declaration)):

```text
app dashboard
  needs display net
  serves svc
  applications erx_dashboard
```

The field's one value is `svc`, a closed set the grammar checks, so
nothing else can be declared served. It grants the app nothing: it lets
the sessions that may command apps read and command this one. It is
refused beside `program`, since a native app has no `erx_svc`. A start
row carries no service (AP1 of [design-apps.md](design-apps.md#invariants)),
so the declaration lives on the template or the package, where the
build's check and the admission see it.

### The tree

`erx_svc` serves a flat directory:

| File | Read | Write |
| --- | --- | --- |
| `status` | the text the app last set with `erx_svc:set_status/1`, empty until then | refused, `eacces` |
| `ctl` | present only once the app has called `erx_svc:set_ctl/1`; reads as empty | one command a write, handed to the app ([Commanding](#commanding-ctl)) |
| any other name | the bytes the app set with `erx_svc:set_file/2` | refused, `eacces` |

Creating, removing or renaming a file answers `eacces`, as creating a
file in a directory its caller may not write answers on FreeBSD. A tree
whose app takes no commands has no `ctl`, so `ls /svc/ntpd` shows what
ntpd offers and nothing that refuses every write.

### A status line

`status` holds one attribute a line:

```text
NAME <tab> VALUE <newline>
```

NAME is a system identifier, `[a-z0-9][a-z0-9_-]*` of at most 63 bytes
([design.md](design.md#decisions)), at most once in a file. VALUE is text
the field escape writes, `erx_text:escape_field/1`
([design-live.md](design-live.md#attributed-text)): tab, newline and
backslash as `\t`, `\n` and `\\`, and every byte of a character a display
would escape as `\x` and two hexadecimal digits. This is the form of a
`/proc` `status` file's first two fields, so a program that reads one
reads the other, and `erx_text:unescape_field/1` recovers each value's
bytes. An attribute the app holds no value for is left out, and a reader
shows a missing attribute as `[unknown]`, never as a value.

The SDK writes it: `erx_svc:set_status([{Name, Value}])` takes
identifiers and text, escapes each value, renders the lines and keeps
them. One parser reads it, `erx_svc_status:parse(Bytes)`, which returns
each line as `{Name, Value}` with the value still escaped, or `invalid`
for a line that is not an identifier, one tab and a field
`unescape_field/1` accepts, for a repeated name and for a last line with
no newline. It reads at most `svc_status_max`, 64 KiB; a longer file is
cut and its last entry is `partial`.

### The grant

For each live session `S` whose template holds `start` and each name
`NAME` with a provider, the domain service keeps one grant record, keyed
by `S` and `{svc, NAME}`. It is the record of
[design-system.md](design-system.md#facets-a-configured-domain-serves)
("One operation per grant"), with no manifest row behind it: its pair is
NAME's provider and `S`, its rights are `rw`, and its quantities are
those of a facet row the build derives
([design-packaging.md](design-packaging.md#the-apps-row);
`abi/services/files.txt`). The facet is installed under `{svc, NAME}`,
NAME a binary, so a session's registry makes no atom from an app's name.
`svc` is no service row of the manifest: like the `code_objects` facet,
it is granted by the domain service's own policy
([design-system.md](design-system.md#creating-a-domain)), as an instance
of the `files` interface.

### The namespace entry

A session whose template holds `start` has one entry at `/svc`:

```erlang
#{point => [<<"svc">>],
  provider => {facets, svc},   % a directory of the registry's svc facets
  root => [],
  rights => rw,
  nosymfollow => true}
```

`{facets, svc}` is a provider kind of the namespace
([design-files.md](design-files.md#namespaces)): a directory whose
entries are the names of the `svc` facets the domain's registry holds at
each resolution, each a directory that is the root of that facet's grant.
`nosymfollow` is an entry field, false unless a mount asks for it. A
session without `start` has no such entry, and `/svc` is the release
slice's empty directory, as `/data` is where no `data` facet is granted
([design-files.md](design-files.md#building-binding-and-mounting), "A
facet's mount").

### What /proc keeps

`/proc` keeps the kernel's, the system services', the configured
domains' and each runtime's records about its own processes. Of an app it
keeps what the start service observes, at `/proc/apps/NAME`: the row,
its state, its reason, its domain and its settings
([design-apps.md](design-apps.md#interfaces)); and what any domain's
runtime reports of an app's session at `[domains, Id]` and its processes.
The `ntp` kind, its path `[ntp]` and its value types `ntp_servers`,
`ntp_last` and `net_addresses` are not in the schema.

## Algorithms and behavior

### Serving: `erx_svc`

`erx_svc` is a module of the `erx` library application, which every
runtime carries. A session's runtime starts it before its ready report
when the domain service has told the session, in its start, that its
template serves `svc`, and calls `erx_facet:provide(svc, Pid)`, so the
report names it ([design-system.md](design-system.md#facets-a-configured-domain-serves),
"Providers"). It is the mint and the tree's `erx_fs` server in one
process. Its end ends the session, as a mint's end ends its domain, and
the start table's keeper starts the next.

The app's processes set what the tree shows with `set_status/1`,
`set_file/2` and `set_ctl/1`, each a message to `erx_svc`. A read is
answered from what `erx_svc` holds, so no read waits on the app's own
loop. That is the honest app's property; a reader still bounds its wait,
since the session's runtime as a whole is untrusted
([Reading with a deadline](#reading-with-a-deadline)).

### Providing

The domain service accepts `svc` in a session's ready report, under the
rules of "Providers" in
[design-system.md](design-system.md#facets-a-configured-domain-serves)
with a session in place of a configured domain's incarnation:

* the session's principal NAME has a start row, from the manifest or an
  admitted package ([design-packaging.md](design-packaging.md#the-start-tables-rows)),
  and its template declares `serves svc`; a report that provides `svc`
  otherwise is refused, logged and counted, and the rest of the report
  stands;
* the mint is a pid the session owns, node and creation both, as for a
  configured domain;
* `svc` is the only name a session may provide; a `provides` map naming
  any other is refused whole;
* NAME's provider is its newest live session that provides `svc`. A
  report from an older session than the newest provides nothing.

The name is the principal's, which the domain service gave the session
when it made it. A session cannot choose another, and the admitted names
are unique, so no app squats another's name.

### Granting

The grant records follow two events besides those of
[design-system.md](design-system.md#facets-a-configured-domain-serves):

* **a provider's ready report** adds a record `{S, {svc, NAME}}` for each
  live session `S` whose template holds `start`, and a provider's end
  moves each such record to `idle` and ends nothing the end did not;
* **a session's ready report**, for a template that holds `start`, adds a
  record for each name that has a provider; its end deletes its records.

Each record then runs the existing operation: introduce, mint, install,
under one deadline of 10 s, with a fresh tag, failing once for the pair
and logging. The mint's request carries the grantee's principal, so
`erx_svc` knows who holds each facet; it binds no tree differently by
principal. The installation sends `{Pid, rw}`.

The system domain holds no `svc` grant, so the trusted base reads no
bytes an app serves, and its command shell shows an app's run state from
`/proc/apps` alone.

### Mounting and resolving `/svc`

`erx_ns:mount_facets/1` mounts the `/svc` entry in a session whose
template holds `start`, with `nosymfollow`, at the point `erx_ns`'s one
table of points names. The entry is there from the session's start
whether any app serves, so the session's table changes with no app's
coming or going.

A resolution that reaches `/svc`'s directory lists, after the release
slice's empty directory, one entry of kind `directory` for each `svc`
facet the registry holds then, sorted by name. A walk of `NAME` below it
reads the registry's `{svc, NAME}`: a facet there gives its grant, and
the walk goes on at that grant's root; none answers `enoent`. So
`/svc/NAME` exists exactly while a facet for it is installed, and the
table holds one entry however many apps serve, within `ns_mounts_max`
(64) whatever the 256 start rows `start_rows_max` allows.

### Links

The resolver follows no link that lies in a tree it reached through an
entry with `nosymfollow`. Where it would follow one (a link before the
last name, a last link the operation's row of the table in
[design-files.md](design-files.md#resolving-a-path) follows, or a
trailing `/`), it answers `eacces`, as FreeBSD's `vfs_lookup` does on a
`nosymfollow` mount. An operation that acts on the link itself
(`read_link`, `read_link_info`, `delete`) acts on it, as FreeBSD's
mount(8) says.

A bind takes the flag of the entry its place lies on, and a program's
table takes its starter's entries' flags with them
([design-files.md](design-files.md#narrowing-for-a-program)). A mount or
bind may set the flag and never clears one, so following only narrows.
`erx_ns:mount/3` refuses, with `einval`, a provider that names an `svc`
facet by name, so the system makes no entry to an app's tree but `/svc` and its binds; a mount of a grant's bare pid, `{grant, Pid, Tree}`, that a session's own code makes is its own choice, as a FreeBSD mount without `nosymfollow` is root's.

### Reading with a deadline

`erx_svc_client` is the one way a system command reads or commands an
app's tree:

* `read(Path, Max)` spawns a process that opens `Path`, reads at most
  `Max` bytes and closes, and waits for it until `svc_wait_max`, 5 s,
  `{ok, Bytes}`, `{error, Errno}` or `timeout`. At the deadline it ends
  the process with `kill`. Its reply goes to an alias that ended with it,
  and its fids are clunked when its end reaches the grant
  ([design-files.md](design-files.md#fid-owners)); a hung server keeps
  the request, within its grant's 64 in flight, in its own memory, and
  answers the clunk when it settles it or never.
* `command(Path, Line)` does the same with one write, and answers `ok`,
  `{error, Errno}` or `unknown`. `unknown` is the answer for a deadline
  that passed: the command may have taken effect, may yet, or may not.
  The caller reports it as unknown and never writes again on its own.

Interactive use needs no deadline. `cat /svc/NAME/status` and
`echo CMD > /svc/NAME/ctl` wait as a read or a write of any file does,
and `Ctrl-C` ends them: the shell ends every Erlang process of the
foreground job by marking its tag
([design-shell.md](design-shell.md#job-control)), and the file call's process
ends with it. A write that `Ctrl-C` cut off has an unknown outcome, as it
has on UNIX.

### Commanding: `ctl`

A write to `ctl` is one command: the bytes of one write at offset 0, at
most `svc_ctl_max`, 4,096 bytes, one line, its trailing newline optional,
as `/etc/start/ctl` takes them
([design-apps.md](design-apps.md#interfaces)). A write that breaks this
answers `einval` and reaches no handler. `erx_svc` sends the line,
without its newline, to the process the app named with `set_ctl/1`, in
the order the writes arrive, and the write waits for the answer:

* `ok` makes the write succeed with the bytes written;
* `{error, Errno}`, an errno of the file protocol
  ([design-files.md](design-files.md#errors)), fails the write with it;
* any other answer, or the handler's end, fails it with `eio`.

A 9P write carries no text back, so a command's refusal is its errno,
and its reason goes to the app's log. The line is untrusted input to the
app: each grammar an erXos app defines for its `ctl` has a fuzz target of
its own, landing with it.

### Lifecycle

| Event | What follows |
| --- | --- |
| an app's session starts | `erx_svc` before the ready report; the report provides `svc`; the domain service grants each live session that holds `start`; `/svc/NAME` appears in each as its installation is acknowledged |
| a session that holds `start` starts | one `/svc` entry at its start; at its ready report a record for each provider, so it sees every running app's tree |
| the app restarts | its session ends, and with it `erx_svc` and every facet it minted; registries drop `{svc, NAME}`, so `/svc/NAME` answers `enoent`, and a descriptor open on the old grant answers `eio` (F10); the next session provides and is granted anew. No old grant reaches the new session, since a facet is a process of the session that minted it |
| `service NAME stop` | the session ends, as above, and no successor provides |
| a session that holds `start` ends | its records are deleted and the facets bound to it end |
| `service NAME purge`, a package removed | nothing of the tree is kept anywhere, so neither has anything to remove from it; a removed package has no row and so no provider |
| an introduction or mint fails | the record is `failed` for that pair and logged ([design-system.md](design-system.md#facets-a-configured-domain-serves)); `/svc/NAME` is absent in that session until either side restarts |

### What the commands show

**`service NAME status`** writes the row's state from `/proc/apps/NAME`,
as [design-apps.md](design-apps.md#interfaces) says, and then, for a row
whose state is `running`, the app's own words: each line of
`/svc/NAME/status` that `erx_svc_status:parse/1` accepts, as it is
written, NAME, a tab and the escaped value, and `[invalid]` for each line
it does not, `[partial]` last where the file was cut. A valid line holds
no character the line escape changes, so it is shown as written, never
unescaped. A read that fails writes `service: /svc/NAME/status: ` and
the errno's text, or `timed out`, to standard error; `enoent` there means
the app serves no tree or its grant is not installed. The exit status is
the run state's, as FreeBSD's `status` returns, and a failed read of the
app's words does not change it.

**`ntpctl -s status`** and **`-s peers`** read `/proc/apps/ntpd` and then
`/svc/ntpd/status` ([design-time.md](design-time.md#what-ntpd-serves)).

**`service NAME CMD [ARG ...]`** reaches an app's own commands, as a
FreeBSD script's `extra_commands` run its own verbs. A CMD that is one
of rc.subr's own keywords (`rcvar`, `enabled`, `delete`, `describe`,
`extracommands`, and the verbs `service` itself offers,
[design-apps.md](design-apps.md#interfaces)) never reaches an app: one
`service` does not offer is refused with its usage line and status 1,
as rc.subr refuses a verb it does not know. For any other CMD, `service`
first reads `/proc/apps/NAME`, as `status` does: a name with no row and
a configured domain answer as `start` does for them, and a row that does
not run answers `NAME not running?`, each with status 1. For a running
row it writes the line `CMD ARG ...` to `/svc/NAME/ctl` through
`erx_svc_client:command/2` and answers from that write alone: status 0
when it succeeds; `enoent`, an app that takes no commands, as its usage
line; at `svc_wait_max`, `service: NAME: CMD: outcome unknown`, since
the app may have run it; and any other errno as `service: NAME: CMD: `
and its text; each failure with status 1 and on standard error.

**`cat /svc/NAME/status`** writes the file's bytes unchanged, as `cat`
writes every file. An honest app's file holds only what the field escape
writes; a hostile app's may hold anything, and `cat` shows it as it shows
any file another principal wrote ([Security](#security)).

## Interfaces

* **Erlang, in an app's session**: `erx_svc:set_status/1`,
  `erx_svc:set_file/2`, `erx_svc:set_ctl/1` (a pid that takes
  `{erx_svc_ctl, From, Line}` and answers with `erx_svc:reply/2`).
* **Erlang, for readers**: `erx_svc_client:read/2`,
  `erx_svc_client:command/2`, `erx_svc_status:parse/1`.
* **Namespace**: the provider kind `{facets, svc}`, the entry field
  `nosymfollow` ([design-files.md](design-files.md#namespaces)), the
  `/svc` point in `erx_ns`'s table.
* **Manifest and packages**: the template field `serves` and the
  `app.txt` field `serves`, each with the one value `svc`, in their packed
  records (`abi/manifest.txt`, `abi/formats/package.txt`).
* **Limits**, in `abi/services/files.txt` beside the `files` interface:
  `svc_wait_max` 5,000 ms, `svc_status_max` 65,536 bytes,
  `svc_ctl_max` 4,096 bytes.
* **The inspection schema** loses the `ntp` kind, the path `[ntp]` and
  the types `ntp_servers`, `ntp_last` and `net_addresses`, and its generator gains the
  check of AT1.

## Failure handling, diagnostics and debuggability

| Failure | Detected by | Effect | Recovery |
| --- | --- | --- | --- |
| the app's runtime hangs | `erx_svc_client`'s deadline | `service` and `ntpctl` write `timed out` and go on; the request stays at the app, within its grant's 64 in flight; a 65th waits in the client or fails `emfile`, still within the deadline | the app's restart, which ends its grants |
| the app answers a command after the deadline | the deadline | the caller reports `unknown`; the command may have taken effect | the operator reads `status` and decides |
| the app writes a malformed status | `erx_svc_status:parse/1` | that line shows `[invalid]`; the others show | the app's fix |
| the app serves a link | the resolver | `eacces` for any operation that would follow it | none needed |
| the app's session ends | the facets' ends | `/svc/NAME` is gone; open descriptors answer `eio` | the keeper's restart |
| a session reports `svc` it may not provide | the provider rule | refused, logged and counted; the session runs on without a tree | the template's or package's declaration |
| the grantee is at its `connections` limit | the introduction | the record fails for the pair and is logged; `/svc/NAME` is absent there | either side's restart, or fewer apps |

## Security

* **Who may read and command.** Every session whose template holds
  `start`, and no other, holds an `rw` grant of each running app's tree:
  whoever may start and stop an app may read its words and give it its
  commands. In a release build that is an administrator's template
  ([design-apps.md](design-apps.md#interfaces)). The app chooses none of
  it (AT8).
* **What a grant gives the app.** Nothing of the reader's: the app sees
  the reader's principal in its mint request, the reader's requests on
  its own tree and the lines written to its `ctl`. It reaches nothing of
  the reader's namespace and holds no capability of the reader's.
* **Names.** NAME is the providing session's principal, unique by
  admission, never a word of the session's (AT2). An app that is not
  running has no tree, so nothing stands in its place.
* **Links.** An app's tree cannot redirect a reader: no link in it is
  followed (AT4), so `echo x > /svc/app/ctl` writes the app's `ctl` or
  fails, and never reaches `/etc/start.conf`.
* **Code.** Nothing in an app's tree runs (AT5).
* **Old grants.** A grant ends with the session that minted it, so a
  restarted app's readers reach only the new session's tree, and only by
  a new open (AT3).
* **Waiting.** No system command waits on an app beyond `svc_wait_max`
  (AT6). What a hung app holds is its own: the grant process, its
  requests and its fids are the app's domain's memory.
* **Text.** `service` and `ntpctl` show an app's words only as lines the
  parser accepted, each one display-safe by the field escape's
  construction (AT7). `cat` passes a file's bytes unchanged, as on UNIX,
  where root's `cat` of a file another user wrote shows whatever it
  holds; a hostile app can send controls to the terminal of an
  administrator who `cat`s its file, as any principal can through a file
  in its home ([Decisions](#decisions), 2).
* **Cost an app imposes.** One introduction for each session that holds
  `start`, paid from both sessions' budgets
  ([design-domains.md](design-domains.md#introduction-and-connection-down)), and only for
  an app whose template or package declares `serves svc`. The count is
  bounded by the start rows.
* **The trusted base** reads no app's bytes: the system domain holds no
  `svc` grant.

## Verification and testing

Each test is paired with the fault that proves the code ran.

* **The status format.** Host properties of `erx_svc_status`: every list
  of identifiers and binaries `set_status/1` renders parses back to
  itself; a raw tab or newline inside a value, a raw `0x1b`, `\x41`, a
  lone backslash, a name outside the identifier form, a repeated name and
  a last line without a newline each give `invalid`; a file of
  `svc_status_max` + 1 bytes ends with `partial`. Seeded: a parser that
  accepts a raw `0x1b` in a value; the property finds it.
* **Fuzz target** `erx_svc_status:parse/1`, landing with it, whose
  oracle is that every value it accepts is accepted by
  `erx_text:unescape_field/1` and holds no byte the line escape changes.
  Seeded: the same raw `0x1b`.
* **A link in an app's tree is not followed.** In hosted mode and in the
  QEMU suite, a test app serves `ctl` as a link to a file of root's,
  `/tmp/target`. `echo x > /svc/linkapp/ctl` and `cat /svc/linkapp/ctl`
  answer `eacces`, `/tmp/target` is unchanged, and `ls -l` shows the
  link. A bind of `/svc/linkapp` at `/mnt` refuses the same. Seeded: a
  resolver that ignores `nosymfollow`; the test finds `x` in
  `/tmp/target`. Seeded: a bind that drops the flag; the bind case finds
  it.
* **A stale grant after a restart.** A test app sets `status` to its
  session's name. The test opens `/svc/app/status`, restarts the app,
  reads the old descriptor (`eio`), opens again and reads the new
  session's name. Seeded: the domain service keeps the older session as
  provider when the newer reports (the newest rule removed); the test
  reads the old name, or both sessions' grants answer.
* **A hung server does not hang `service NAME status`.** A test app
  whose `erx_svc` stops answering after its first read. `service hung
  status` returns within `svc_wait_max` plus 1 s, writes `timed out` to
  standard error and its run state to standard output; run 70 times, every
  run still returns within the bound. Seeded: `service` reading
  `/svc/NAME/status` in its own process; the test's deadline fails.
* **A command cut off is not repeated.** A test app's handler sleeps past
  `svc_wait_max`, then counts the command. `erx_svc_client:command/2`
  answers `unknown`, and the count is 1 after the handler finishes.
  Seeded: a client that writes again after `timeout`; the count is 2.
* **`service NAME CMD` answers from the write.** A test app whose
  handler answers `ok`, `{error, eperm}` and a sleep past
  `svc_wait_max`: `service` exits 0, prints `eperm`'s text, and prints
  `outcome unknown`, each failure with status 1; `service ntpd reload`,
  ntpd having no `ctl`, prints the usage line; `service NAME enabled`
  and `service NAME delete` never reach the handler, whose count stays
  0. Seeded: `service` forwarding every verb not in its table; the count
  is 1.
* **The provider rule.** Host tests of the domain service: a report
  providing `svc` from a template without `serves svc`, from a principal
  with no start row, from an older session, with a mint of another
  domain, or naming another service, is refused and counted. Seeded: the
  declaration check removed; the first case installs `/svc/NAME`.
* **Who holds grants.** A session whose template holds no `start` has no
  `/svc` entry and no `svc` record; the system domain has none. Seeded:
  records made for every session; the test finds a grant.
* **Escape at display.** A test app whose status holds an invalid line
  with a raw `0x1b`: the captured output of `service app status` holds no
  `0x1b` and shows `[invalid]`. Seeded: `service` printing lines it did
  not parse.
* **AT1.** The schema generator refuses a seeded `kind` reported by
  `runtime` at a machine path, the `ntp` row as it stood.
* **ntpd.** The QEMU suite's ntpd case reads `/svc/ntpd/status` during a
  resolution that the test peer delays by 8 s, and gets an answer at
  once. Seeded: `erx_svc`'s read callback asking ntpd's loop; the read
  times out ([design-time.md](design-time.md#verification-and-testing)).

## Alternatives considered

* **The read and write split**: an app's status as typed records under
  `/proc/apps/NAME/NODE` through the inspector, its commands in a tree
  of its own. The inspector would have to route a path to an app's
  runtime, which needs a way to find the app's domain and an agent bound
  that admits paths outside it, and install-time declarations of each
  app's nodes and types; an app's words would live in two places with
  two gates. Typed does not mean truthful: a record an app reports is
  its word whatever its type. It keeps a mechanism the owner split does
  not need, and deletes nothing.
* **Typed app kinds in `abi/inspection.txt`**, as `ntp` is: every app
  would edit erXos's schema, which an app installed at run time cannot,
  and the routing above is still missing.
* **App trees mounted under `/proc/apps/NAME/`**: `/proc` is a read-only
  view rendered in the reader's runtime, every field escaped; a tree an
  app serves there would break both promises under the same name.
* **One mount per app**: a table entry for each `/svc/NAME`, mounted and
  unmounted as facets come and go, against `ns_mounts_max` of 64 and up
  to 256 start rows. The `{facets, svc}` directory takes one entry and
  follows the registry with no table change.
* **A relay in the system domain** that reads app trees and serves
  checked text: puts an untrusted parser and a waiting hop in the trusted
  base, and still needs the deadline.
* **An app's own `erx_fs` callback module** as its tree: every read would
  run app code, so a busy app would stall its own `status`, as ntpd's
  `status/1` stalls today, and each app would have to get the server's
  bounds right. The flat tree `erx_svc` serves from what the app set does
  neither.
* **`Tflush` as the deadline**: a server that hangs answers no flush
  ([design-files.md](design-files.md#flush)); ending the reading process
  is the bound that needs nothing from the server.

## Decisions

1. **One `rw` grant to every session that holds `start`.** Whoever may
   command the start table both reads and commands every app's tree. A
   read-only grant for a wider set of sessions would take a second grant
   record and a policy of who reads; a wider reader is a later consumer's
   to ask for.
2. **`cat` of an app's file passes its bytes.** An app's controls reach
   the terminal of an administrator who `cat`s its file, as with any file
   another principal wrote, and the administrator's documentation says
   so; `service` and `ntpctl`, which show an app's words under its name,
   escape them ([What the commands show](#what-the-commands-show)). A tree
   whose reads are filtered on the reader's side would make `cat` lie
   about a file's bytes.
3. **`service NAME CMD` reaches an app's own commands.** As FreeBSD's
   `extra_commands` let `service NAME reload` run a script's own verb,
   `service` writes a verb that is neither its own nor one of rc.subr's
   keywords, with its arguments, to `/svc/NAME/ctl`
   ([What the commands show](#what-the-commands-show)).
4. **Grants follow the ready reports.** Every session that holds `start`
   is introduced to every serving app by the two sessions' ready reports,
   one connection each from both budgets ([Granting](#granting)). The
   count is bounded by the start rows and needs no new request; a grant
   made at the first walk of `/svc/NAME` would need one, a request to the
   domain service. What the connections cost is a watch-list item
   ([todo-performance.md](todo-performance.md)).

## References

* [CLAUDE.md](../CLAUDE.md), "No new mechanism without a design that
  names it".
* [design.md](design.md#decisions), the three homes.
* [design-live.md](design-live.md#the-proc-tree), [design-apps.md](design-apps.md#interfaces),
  [design-system.md](design-system.md#facets-a-configured-domain-serves),
  [design-files.md](design-files.md), [design-packaging.md](design-packaging.md#the-declaration),
  [design-time.md](design-time.md#what-ntpd-serves), [design-shell.md](design-shell.md).
* FreeBSD releng/15.1, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
  from the project's GitHub mirror,
  `https://raw.githubusercontent.com/freebsd/freebsd-src/`:
  * `sbin/mount/mount.8`, SHA-256
    `a9f016233c54d5fb8b3c0e63f8b4af754101c375f4de60648326db29759dd689`;
  * `sys/kern/vfs_lookup.c`, SHA-256
    `d1e4ccd344058b5fe02f3d54b8c219848a6390d69b9a1bb4c4d6da899b354546`;
  * `libexec/rc/rc.subr`, SHA-256
    `f934e89957223f4816821a3ccf2e8f476d28d906358cdf06cfd6db65ab44cbb1`.
