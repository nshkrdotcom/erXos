# Board sensors: the Raspberry Pi firmware's readings

The Raspberry Pi 4's SoC temperature, its core and SDRAM voltages, its
clock rates and its throttle and under-voltage state are known only to
the VideoCore firmware, which answers for them through the property
interface of its mailbox. This document says who asks the firmware, how
often, how its answers are checked, where the readings appear
(`/proc/sensors`), who acts on them (the console's warnings; no thermal
policy), and how QEMU's model and the board check them. It extends the
firmware request of
[design-kernel.md](design-kernel.md#firmware-requests) and keeps PL2 of
[design-platforms.md](design-platforms.md#invariants): no driver reaches
the firmware.

Decisions every reader needs:

* **Every firmware request after boot is a row of the platform record.**
  The record lists the firmware requests a platform makes, each a fixed
  tag and fixed argument words, belonging to a device entry or to the
  machine. A notification (the VL805's, the Bluetooth controller's
  power) is a row whose answer is empty; a sensor reading is a row whose
  answer is two words, or a short text. One kernel call,
  `erx_firmware_request(resource (CARVE), index)`, the call the USB
  design defines for the VL805's notification, sends a row and returns
  its answer; the caller chooses only the row.
* **The tags and the readings are closed sets the ABI declares.** Each
  tag has the size of its request and of its answer window, so the
  kernel never takes a length or an offset from the firmware's reply,
  and a tag that reads the board's key, runs code on the VideoCore or
  sets a clock or a voltage cannot be written in a row. Each reading
  names its tag and argument, so a machine row is a reading's name and
  nothing else.
* **One poll, one sender.** `erx_board_sensors`, a supervised process of
  the system domain, asks the device service for every machine row once
  every 5 s. The device service makes every firmware request from its
  one firmware worker, so its own process never waits on the mailbox
  and answers the watchdog's liveness call throughout. Readers of
  `/proc/sensors` read the latest poll and never cause a request.
* **Values the firmware does not give are shown as such.** A tag the
  firmware ignores reads `[unsupported]`, a mailbox that stops answering
  `[timeout 1000]`, a malformed answer `[error]`, and a platform with no
  rows, QEMU `virt` among them, `[unsupported]` throughout.

## Context

### What the firmware offers

The facts below come from the firmware's mailbox property interface page
(the firmware wiki, "Mailbox property interface"), the firmware's own
manual page of the same interface (`vcmailbox.7` in Raspberry Pi's
`utils`), Raspberry Pi's documentation of `vcgencmd`, and FreeBSD's
driver ([References](#references)).

**The property interface.** The ARM side writes a buffer in memory and
posts its address on mailbox channel 8; the firmware writes its response
over the request, in the same buffer, and answers with the same address
(wiki, lines 1-2, 14-20). The buffer is 16-byte aligned (line 3) and
holds its size in bytes, a request or response code, a sequence of tags
and an end tag of 0 (lines 22-34). A response code of `0x80000000` is
success and `0x80000001` an error parsing the buffer (lines 29-30). Each
tag is its identifier, the size of its value buffer, a request or
response word and the value buffer; in a response, bit 31 of that word
is set and bits 30-0 give the value's length (lines 36-47). Unknown tags
are ignored, without the response bit (line 5; `vcmailbox.7:33`); a
response may carry tags nobody asked for (line 6); a response longer
than the value buffer is truncated to it, and its length word then gives
the length the firmware wanted (lines 7-10; `vcmailbox.7:43`).

**The readings.** Each is a tag whose request is one word, an id, and
whose response is the id and a value:

| Reading | Tag | Id | Value | Source |
| --- | --- | --- | --- | --- |
| SoC temperature | `0x00030006` | 0 | thousandths of a degree Celsius | wiki 525-537; `vcmailbox.7:1045-1072`; FreeBSD `bcm2835_mbox_prop.h:258`, `bcm2835_cpufreq.c:596-633` |
| maximum safe temperature | `0x0003000a` | 0 | thousandths of a degree Celsius; "overclock may be disabled above this temperature" | wiki 539-552; `vcmailbox.7:1074-1102`; `bcm2835_mbox_prop.h:259` |
| voltage | `0x00030003` | core 1, SDRAM_C 2, SDRAM_P 3, SDRAM_I 4 | see below; `0x80000000` means the id is not valid | wiki 456-476; `vcmailbox.7:905-952`; `bcm2835_mbox_prop.h:187-192` |
| measured clock rate | `0x00030047` | ARM 3, CORE 4 | hertz, "the true/actual clock rate ... which respects clamping, throttling and clock divider limitations" | wiki 236-241, 363-375 |

The voltage's unit is in dispute between the sources. The wiki gives
"absolute voltage in microvolts" (line 473), and its set-voltage rule
treats any value of 500000 or more as absolute microvolts (line 487);
`vcmailbox.7:946` gives an "offset from 1.2V in units of 0.025V". In
FreeBSD the comments and sysctl descriptions say the same offset
(`bcm2835_cpufreq.c:444, 459, 1282-1311`), but its code treats the
value as microvolts: `OFFSET2MVOLT` divides it by 1000 (`:64`), and the
boot message prints the four voltages through it in millivolts
(`:1112-1117`). So the documents disagree, and FreeBSD's arithmetic
sides with the wiki. Probe S1 settles which the board's firmware
answers ([Verification](#verification)).

The configured clock rate, tag `0x00030002`, is in every source (wiki
298-310; `bcm2835_mbox_prop.h:131`), but it is "the last requested
value", not the running one (wiki 375); `vcmailbox.7` and FreeBSD do
not list the measured tag, so whether the board's firmware answers it is
for probe S1.

**The throttle state.** Raspberry Pi documents `vcgencmd get_throttled`
as a bit pattern: bit 0 under-voltage detected, 1 ARM frequency capped, 2
currently throttled, 3 soft temperature limit active, and bits 16 to 19
that each of those has occurred (`graphics-utilities.adoc:45-84`). No
source read for this design names a property tag that returns that word:
the wiki, `vcmailbox.7` and FreeBSD's headers do not. `vcgencmd` itself
reaches it through the property tag `0x00030080`, `GET_GENCMD_RESULT`,
whose value buffer holds an error word and then the command's text,
NUL-terminated, which the firmware overwrites with its reply text
(`vcgencmd.c:84-115`); a nonzero error word is the VideoCore's error
(`vcgencmd.c:115, 126`), and `vcgencmd` prints the reply text as the
firmware wrote it (`vcgencmd.c:113, 162`). The reply's text for
`get_throttled` is stated by no source read: its form is unverified and
probe S1 records it. Nor does any source say over what span an occurred
bit reports, since boot or since the state was last read; probe S1
records that too.

**What the firmware does by itself.** It throttles the ARM cores between
80 and 85 degrees Celsius and the ARM cores and the GPU above 85
(`overclocking.adoc:370`), resets clocks and voltages to their defaults
at `temp_limit`, 85 by default and at most (`overclocking.adoc:5, 98-99`),
and throttles both when the supply falls below 4.63 V, plus or minus 5
percent (`overclocking.adoc:380`). The board protects itself; nothing in
erXos has to act for it to survive heat or a weak supply.

**What else the interface can do.** The same channel allocates and locks
VideoCore memory and executes code on the VideoCore (wiki 554-622), and
can read the board's private key, which is why only the kernel reaches
it (PL2, [design-platforms.md](design-platforms.md#device-secrets)).

### What FreeBSD does

`bcm2835_cpufreq` reads each value when a sysctl is read, under the
driver's lock and the mailbox's channel lock (`bcm2835_cpufreq.c:966-986`;
`bcm2835_mbox.c:409`), and shows the temperature as
`hw.cpufreq.temperature`, in thousandths of a degree, and as
`dev.cpu.0.temperature`, in tenths of a kelvin (`bcm2835_cpufreq.c:988-1010,
1176-1185, 1313-1318`). It does not poll and reads no throttle state.
Its mailbox code checks that the answer names the request's buffer, that
the response code is success and that each tag's response bit is set
(`bcm2835_mbox.c:348-374`), walks the tags by the value-buffer size read
back from the buffer the firmware wrote (`:358-386`), and waits 10 s for
an answer (`:244-247`). It records one exception: for the set-GPIO-config
and set-GPIO-state tags, `0x00038043` and `0x00038041`
(`bcm2835_firmware.h:144-146`), the firmware leaves the response word 0,
and FreeBSD then takes the answer as complete (`bcm2835_mbox.c:362-370`).
`0x00038041` is the tag of the Bluetooth power line's notifications
([design-bluetooth.md](design-bluetooth.md#the-power-line)).

### What QEMU's model gives

QEMU's `raspi4b` model emulates the property interface on channel 8, and
answers the framebuffer's tags, as the framebuffer's test stand-in
shows ([design-platforms.md](design-platforms.md#bring-up-under-qemu)).
Which of the tags above it answers, and with what values, is unverified:
this design reads no QEMU source, and probe S2 records the model's
answers.

## Requirements

1. Show the Pi 4's SoC temperature and maximum temperature, its core and
   three SDRAM voltages, its throttle and under-voltage state, and its
   ARM and core clock rates, to the inspector and at `/proc`.
2. Tell the console when the board is under-voltage, capped or throttled,
   and when that clears.
3. Keep PL2: no driver reaches the firmware, and no domain chooses what
   the firmware is asked.
4. Read every answer as device-written memory: bounded, and checked
   before use.
5. Never show a value the firmware did not give: an absent, ignored,
   late or malformed answer is shown as its status.
6. Keep the firmware notifications working beside the readings.
7. Keep the device service answering the watchdog's liveness call
   while the firmware is asked, however long the mailbox takes.
8. Hold what another domain's firmware requests make the system domain
   spend to that domain's facet: one request in flight, and the time
   the mailbox takes charged to its share.

Non-goals: a thermal policy in erXos, since the firmware throttles by
itself and no consumer needs another; setting clocks or voltages; the Pi
5, whose record gains rows when its port checks them; the PMIC's
readings, which `vcgencmd` reaches on the Pi 4 and Pi 5 through
commands this design does not send.

## The construction: the firmware's requests are rows of the platform record

The platform record already lists, for a device entry, the notifications
that `erx_firmware_request` sends
([design-bluetooth.md](design-bluetooth.md#the-power-line)), and that
call already serves one request at a time, against one buffer, with one
deadline and one rule after a timeout
([design-kernel.md](design-kernel.md#firmware-requests)). A sensor reading
differs from a notification in one thing only: its answer is wanted. So
this design does not add a second route to the firmware. It widens the
row and the call:

* **A row** is a name, what it belongs to (a device entry's path, or
  `machine`), a tag from the ABI's closed set, and the tag's argument
  words. The tag's declaration fixes the size of the request and of the
  answer window; the row cannot. A machine row is written as a reading's
  name alone, a member of the closed set `fw_reading`, whose declaration
  gives the tag and the argument; the generator derives the row's other
  fields from it.
* **The call**, `erx_firmware_request(resource (CARVE), index)`, sends
  row `index` among the rows of what the resource names, a device's
  resource naming that device's rows and the root resource naming the
  machine's, and returns a status and, on success, the answer: at most
  the tag's window, never more than the firmware wrote. A notification's
  window is empty, so for the VL805 and the Bluetooth line the call
  returns a status alone, as the USB design defines it.
* **One worker sends.** The device service makes every call from its
  firmware worker, one at a time, while its own process takes requests
  and answers every other call
  ([design-system.md](design-system.md#devices), "Firmware requests");
  the sensor driver asks it for each machine row in turn.
* **A request costs what it took.** The runtime charges a dirty NIF its
  elapsed time on either pool of dirty schedulers, as ERTS already
  charges one on a dirty CPU scheduler, so the worker's kernel call
  shows in its reductions like any other work. The worker returns the
  reductions its call took with the answer, and the device service's
  serving path counts them in the reply's cost, which is what a facet's
  admission accounts ([design-scheduler.md](design-scheduler.md#service-work)).

Each requirement then follows:

* **PL2 holds, by construction.** The mailbox's registers stay with the
  kernel's one request routine (and the boot-time key read and the trial
  request, which are not rows). What the firmware is asked is a row of
  the record the build checked, so a domain, or the system domain's own
  code, can choose only which row; and the key read's tag, the
  code-execution and memory tags and the tags that set a clock or a
  voltage are not in the closed set, so no row can name them.
* **A row and its attribute cannot disagree.** A machine row names a
  reading, and the reading's declaration alone gives the tag, the
  argument and the attribute it fills, so a `soc_temperature` row cannot
  send `get_voltage`, and no record can pair them.
* **Bounds by construction.** The kernel lays out the buffer from the
  tag's declaration, reads the response code, the tag word and the
  response word at offsets that declaration fixes, and copies at most the
  declared window. No length, offset or tag count from the reply moves a
  read, unlike FreeBSD's walk by the value-buffer size read back
  (`bcm2835_mbox.c:358-386`).
* **Notifications keep working**, because the firmware worker
  serializes every request, readings included, and a row that times out
  leaves the mailbox in the state the notification's design already
  defines for every caller.
* **The device service stays live.** A request waits up to 1 s in the
  kernel, in the worker; the device service's process never makes the
  call, so the watchdog's liveness call
  ([design-system.md](design-system.md#boot), "The watchdog") is
  answered while a reading or a notification is in flight.
* **Another domain pays for what it asks.** The PCIe domain, the one
  caller outside the system domain, asks through its `pci_bus` facet,
  whose grant takes one request in flight and refuses a second with the
  facet's `{error, busy}`, and whose share is charged each request's
  measured time. So its requests cannot queue up at the worker, and
  however often they succeed, what they spend of the system domain is
  held to the share the grant declares, by the admission every facet
  already runs ([Concurrency and failure](#concurrency-and-failure)).
* **Never fabricating** is shared. The kernel tells an ignored tag
  (`ERX_ENOTSUP`) from a malformed answer (`ERX_EPROTO`); the decoder,
  in Erlang, over a few words the kernel already bounded, checks that
  each answer's id echoes the request's and each value lies in its
  type's range, and shows the firmware's "not valid" value as
  unsupported.
* **Readers cost nothing.** The poll is the only sender, so how often
  `/proc/sensors` is read changes nothing the firmware sees.

## The requests

`abi/formats/vc_property.txt` declares the property buffer's layout (its
header, a tag's header and the end tag), its codes and response bit,
the closed set of tags erXos sends, each with what it may belong to, the
size of its request and of its answer window, the least answer it
accepts and whether the firmware is known to leave its response word 0,
and the closed set of readings below. The generator computes every
buffer size and offset from these facts, derives every machine row from
its reading, and validates every row of every platform record against
them.

| Tag name | Tag | Belongs to | Request | Window | Least answer | Decoded as |
| --- | --- | --- | --- | --- | --- | --- |
| `get_temperature` | `0x00030006` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `get_max_temperature` | `0x0003000a` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `get_voltage` | `0x00030003` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `get_clock_rate_measured` | `0x00030047` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `gencmd` | `0x00030080` | machine | 64 bytes: an error word of 0 and a command of the closed set, NUL-terminated and zero-padded | 64 | 4 | `gencmd` |
| the notification tags | as [design-usb.md](design-usb.md#the-vl805s-firmware) and [design-bluetooth.md](design-bluetooth.md#the-power-line) give them | device | as they give them | 0 | 0 | none |

Every tag but one takes a response word with bit 31 set as performed,
and one without it as ignored, as the interface defines (wiki, line 5).
The exception is the Bluetooth line's `0x00038041`, set GPIO state,
whose response word FreeBSD records the firmware not setting, and whose
word of 0 FreeBSD takes as an answer (`bcm2835_mbox.c:362-370`): its
declaration takes a response word of 0 as performed, an answer of no
bytes, and a nonzero word without bit 31 as ignored. That is a fact
about the tag, so it is written once, in the tag's declaration, and no
caller handles it. On this tag a firmware that ignored the request
cannot be told from one that performed it; the controller's bring-up
after the power cycle is what shows a power line that did nothing, and
probe B-P2 records the raw word the board's firmware leaves
([design-bluetooth.md](design-bluetooth.md#board-probes)).

**The readings** are the closed set `fw_reading`, declared in the same
file. Each reading names its tag, its argument and the attributes it
fills, and the inspection schema's `sensors` kind is generated from the
same declarations:

| Reading | Tag | Argument | Fills |
| --- | --- | --- | --- |
| `soc_temperature` | `get_temperature` | 0 | `soc_temperature` |
| `soc_temperature_max` | `get_max_temperature` | 0 | `soc_temperature_max` |
| `core_voltage` | `get_voltage` | 1 | `core_voltage` |
| `sdram_c_voltage` | `get_voltage` | 2 | `sdram_c_voltage` |
| `sdram_p_voltage` | `get_voltage` | 3 | `sdram_p_voltage` |
| `sdram_i_voltage` | `get_voltage` | 4 | `sdram_i_voltage` |
| `arm_clock` | `get_clock_rate_measured` | 3 | `arm_clock` |
| `core_clock` | `get_clock_rate_measured` | 4 | `core_clock` |
| `throttle` | `gencmd` | `get_throttled` | `throttle`, `throttle_other` |

A platform record's machine rows are readings' names, in the order the
platform polls them, and nothing else. The Raspberry Pi 4's record,
`config/platforms/raspi4b.json`, gains a list `firmware_requests` whose
machine part is the nine readings in the table's order, rows 0 to 8; its
device rows, the VL805's and UART0's notifications, move into the same
list with their tags and arguments. The generator derives a machine
row's tag and argument from its reading and validates every device row
against its tag's declaration, so a row cannot send one reading's tag
under another's name. The rows reach the system domain in the system
manifest, beside the device records
([design-abi.md](design-abi.md#devices-and-partition-windows)), as a
record of name, belonging, tag and argument, and reach the kernel by the
path the notifications take; that path is the kernel's firmware request
([design-kernel.md](design-kernel.md#firmware-requests)), and this design adds
nothing to it.

**The throttle word comes through gencmd.** The one route to it that a
source read for this design states is `vcgencmd`'s: tag `0x00030080`
with the command `get_throttled`. The command is itself a closed set,
`fw_gencmd`, of one member, `get_throttled`, so the text a row sends is
chosen from a list in the ABI, not written in the record. The 64-byte
window is erXos's choice: `vcgencmd` uses 4100 bytes
(`vcgencmd.c:45, 101`). The reading rests on three facts probe S1
confirms before its row and its decoder are built: that the firmware
answers `get_throttled` into a 64-byte value buffer, the exact grammar
of its reply, and the span its occurred bits report. A finding against
any of them comes back to this design before either is built; a
platform record without the `throttle` row shows `throttle` and
`throttle_other` as `[unsupported]`, and its console gets no warnings.

QEMU `virt`'s record has no rows. The Pi 5's has none until its port
checks the same tags on its firmware.

## The kernel call

`erx_firmware_request(resource (CARVE), index)` is the kernel call of
[design-kernel.md](design-kernel.md#firmware-requests), which owns its
contract: its authority, the rows a resource names, its deadline, its
one buffer page and its rule after a timeout, its `ERX_EBUSY` beside a
request in flight, and the checks of the answer and their results. This
design adds the rows (above), the request the mailbox core writes from
a row, and the firmware interface the checks follow.

**The request.** The kernel's mailbox core writes the buffer from the
row and its tag's declaration: the buffer's size and code 0, the tag,
the value buffer's size (the larger of the request and the window), a
request word of 0, the row's argument bytes, zeroes to the end of the
value buffer, and the end tag.

**The interface the checks follow.** `0x80000001` is the firmware's
error parsing the buffer (wiki, lines 29-30); a response word without
bit 31 is the firmware ignoring the tag (wiki, line 5); a response
longer than the window is the truncation the interface defines (wiki,
lines 7-10). `ERX_EPROTO`, the status for an answer that broke the
interface, is a status this design adds to the ABI's list. The window
is at most 64 bytes, well inside the UTCB's 504, and lies inside the
core's own buffer page. The answer is device-written memory, so the
core reads it through the same once-per-field accessors the
notification's response word needs.

The core is the mailbox core of
[design-usb.md](design-usb.md#verification): C17, built for the host,
used by Fiasco's root backend and by erXos's kernel alike.

## The sensor driver

`erx_board_sensors` is a `gen_server` in the system domain, a permanent
child of `erx_domain_sup` started after the device service's process,
and restarted by it like `erx_devfs`. It is the driver of the
firmware's sensors in the sense the system's drivers are: a supervised
Erlang process over a thin shim, here the kernel's request routine,
reached through the device service. Its decisions are in the pure core `erx_board_sensors_core`.

**The poll.** At its start the process asks the device service for the
machine's rows, `erx_devices:firmware_rows(machine)`, the readings'
names in row order, which the domain library's boot view reads from the
system manifest, as it reads the placed devices. An empty list, as on
QEMU `virt`, means the process never polls and every attribute reads
`unsupported`. Otherwise it polls at once and then 5 s after each poll
ends, `board_sensor_period` in `abi/formats/vc_property.txt`, so polls
never overlap and a slow one delays the next instead of piling up. A
poll asks for each row in record order with `gen_server:send_request/2`
on `erx_devices:firmware_read(Reading)`, one row at a time, the next
after the last one's answer, so the process stays free to answer the
inspector while a request is in the kernel, and the device service
holds at most one of its requests at a time. The device service's
firmware worker makes the kernel call through
`erx_domain_lib:firmware(machine, Index)`, and the device service
answers `{ok, Answer}`, the answer bytes, or `{error, Status}`. A device
service that ends during a request answers that request `{error,
failed}` through `send_request`'s monitor, and the poll goes on with the
next row.

**Decoding.** `erx_board_sensors_core:decode(Reading, Reply)` maps one
row's reply to an inspection value
([design-live.md](design-live.md#inspection-records)). The reading's
declaration gives its tag, its argument and its attributes' range, so
the decoder is handed nothing a row could get wrong:

| Reply | Value |
| --- | --- |
| `{ok, <<Id:32/little, V:32/little>>}` for an `id_value` tag, `Id` the reading's argument, `V` within the attribute's range | `{ok, V}` |
| the same with `V` `0x80000000` for `get_voltage` (wiki 476) | `unsupported` |
| the same with `V` outside the range: below 500000 for a voltage, which is what an offset in 25 mV steps would be; 2^31 or more for a temperature; 0 for a clock | `{error, out_of_range}` |
| an `id_value` answer of other than 8 bytes, or whose `Id` is not the reading's argument | `{error, malformed}` |
| `{ok, <<0:32, Text/binary>>}` for `gencmd`, `Text` holding a NUL, the bytes before it in the reply's grammar, its number at most `0xffffffff` | `{ok, Flags}` for `throttle`, and the bits outside the eight named ones as `{ok, Other}` for `throttle_other` |
| a `gencmd` answer with a nonzero error word, without a NUL, or not in the grammar | `{error, malformed}` |
| `{error, enotsup}` | `unsupported`: the firmware ignored the tag |
| `{error, eproto}` | `{error, malformed}`: the firmware's answer broke the interface |
| `{error, etimedout}` | `{timeout, 1000}` |
| `{error, ebusy}` | `{error, busy}`: another request was in flight |
| `{error, failed}` | `{error, failed}` |

What the measured-rate tag answers for a clock it does not measure is
unverified: the configured-rate tag answers 0 for a clock that does not
exist (wiki 310), the measured tag's description says nothing of it
(wiki 363-375), and probe S1 records the raw words. A clock of 0 Hz lies
outside a clock's range, so it reads `[error]`, never a rate and never
a claim that the firmware lacks the clock.

The reply grammar of `get_throttled` is unverified. It is written
`NAME=0xHEX` here, a name, `=`, `0x` and one to eight hexadecimal digits,
from no source; probe S1 records the board's text before the decoder is
built, and the grammar becomes exactly what the probe recorded. Until
then nothing about the throttle state is shown but its status.

The voltage's range follows the wiki's absolute microvolts. If probe S1
finds the board answering offsets, as `vcmailbox.7` says, the decoder's
voltage form changes to 1.2 V plus the offset times 25 mV, and this
section with it; until then an offset reads `{error, out_of_range}`,
never a wrong voltage.

**The snapshot.** After each poll the process holds, for each attribute,
the latest poll's value, with no carry-over of an older good value, and
`sampled`, the monotonic time the poll ended, and `poll_duration`, how
long it took. Before the first poll ends every attribute and `sampled`
are `unknown`. `erx_board_sensors:snapshot/0` returns the snapshot at
once; it never waits on a poll.

**Console warnings.** `erx_board_sensors_core:changes(Reference,
Current)` compares a throttle reading with the **reference**, the flags
the firmware holds just after the last good reading, and returns the
lines to log with `logger`, which reach the console and the store
through the system log
([design-log.md](design-log.md#consumers-and-backlogs)). What the
firmware holds after a read depends on the span its occurred bits
report, which `fw_throttle`'s declaration in
`abi/formats/vc_property.txt` states from probe S1's record: `sticky`,
since boot, or `cleared_by_read`, since the last read. So
`erx_board_sensors_core:after_read(Flags)` gives the next reference: the
reading itself where the bits are sticky, and the reading with bits 16
to 19 cleared where a read clears them, as the read did in the firmware.

| Change against the reference | Level | Line |
| --- | --- | --- |
| bit 0 sets | warning | `erx_board_sensors: under-voltage detected` |
| bit 0 clears | notice | `erx_board_sensors: under-voltage cleared` |
| bit 1, 2 or 3 sets | warning | `erx_board_sensors: ARM frequency capped`, `throttled`, `soft temperature limit active` |
| bit 1, 2 or 3 clears | notice | the same with `cleared` |
| bit 16 to 19 sets while its bit 0 to 3 is clear in the reading and in the reference | warning | `erx_board_sensors: under-voltage occurred between readings`, and likewise for the other three |
| at the first throttle reading of the process, bit 16 to 19 set with its bit 0 to 3 clear | warning | `erx_board_sensors: under-voltage occurred before the first reading`, and likewise |
| the first `{timeout, 1000}` of the process | error | `erx_board_sensors: the firmware's mailbox does not answer; no further readings this boot` |

The one rule then fits both spans. Where a read clears the bits, every
interval between two readings that held a transient sets them against a
reference in which they are clear, so two such intervals in a row log
twice. Where the bits are sticky, the first transient logs and later ones
find the bit already set; a sticky word shows no more than that, and no
poll can change it.

A throttle reading that is not `{ok, _}` changes nothing: the reference
stays, so a malformed reply between two equal readings logs no clear and
set. Where a read clears the bits, a failed reading that cleared them in
the firmware may lose its interval's occurrence; it never invents one.
The lines are fixed text, so nothing the firmware wrote is printed. A
poll logs at most five lines, and a restarted process may repeat the
first-reading lines once per restart, within its supervisor's
intensity.

No other consumer acts on the readings. A thermal policy, a fan driver or
an under-voltage action would read the same snapshot, through the
inspector or a call of its own design; none is designed here.

## `/proc/sensors` and the inspector

The inspection schema gains the kind `sensors` at the path `[sensors]`,
`visible all`, reported by `service`, shown as `/proc/sensors/status`
([design-live.md](design-live.md#the-proc-tree)) and by `erx:i([sensors])`,
the host tool and the web client like any path:

| Attribute | Type |
| --- | --- |
| `soc_temperature`, `soc_temperature_max` | integer 0 to 2^31 - 1, unit `mdegC` |
| `core_voltage`, `sdram_c_voltage`, `sdram_p_voltage`, `sdram_i_voltage` | integer 500000 to 2^31 - 1, unit `uV` |
| `arm_clock`, `core_clock` | integer 1 to 2^32 - 1, unit `Hz` |
| `throttle` | flags `@fw_throttle`: `under_voltage`, `arm_capped`, `throttled`, `soft_temp_limit`, `under_voltage_occurred`, `arm_capped_occurred`, `throttled_occurred`, `soft_temp_limit_occurred`, bits 0 to 3 and 16 to 19 (`graphics-utilities.adoc:45-84`) |
| `throttle_other` | integer 0 to 2^32 - 1: the word's other bits, 0 when the firmware sets only named ones |
| `sampled` | `duration`: the monotonic time the latest poll ended |
| `poll_duration` | `duration`: how long it took |

The units `mdegC`, `uV` and `Hz` are new members of the schema's units;
`fw_throttle` is declared with the property format, in
`abi/formats/vc_property.txt`, as the schema's other `@` types are
declared beside their owners. The collector `erx_sensor_records`, beside
`erx_app_records`, turns `erx_board_sensors:snapshot/0` into the record,
checked by `erx_schema:validate_record/1`; with no sensor driver in the
runtime, as in the rescue configuration, the path is `{error,
unsupported}`, and a driver that does not answer is `{error, failed}`.
Each value renders through `erx_render` as every `/proc` value does, so
a status prints as `[unknown]`, `[unsupported]`, `[timeout 1000]` or
`[error]` (V2).

Every domain whose inspect facet reaches `[sensors]` sees the readings,
as every domain sees the CPUs' idle times. A domain that loads the CPUs
can move the temperature, and another that reads it every 5 s learns
that; the CPUs' idle times, already visible to all, say the same faster,
so the path adds no channel between domains that the machine does not
already show.

## Concurrency and failure

* **One request at a time.** The device service makes every firmware
  request, readings and notifications, from its one firmware worker,
  which starts the next only after the last one's answer, so two never
  meet in the kernel ([design-system.md](design-system.md#devices),
  "Firmware requests"). The queue holds at most one request of each
  caller. For the PCIe domain's bridge that is admission's: the
  `pci_bus` grant's `in_flight` is 1, so its facet forwards a second
  request only after the first one's reply, and refuses one sent
  meanwhile with `{error, busy}`
  ([design-domains.md](design-domains.md#facets)), however many of the
  domain's processes ask at once. The sensor driver and the line
  service are the system domain's own code, inside the trusted base
  and behind no facet; each holds one request at a time because each
  asks the next only after the last one's answer. So a request waits
  behind at most one of each other caller's, each at most 1 s: a
  notification behind at most one reading, a reading behind at most a
  power-cycle step and the VL805's notification. A request a PCIe
  incarnation's facet forwarded before the incarnation ended is still
  served, beside the next incarnation's, so the domain's restart
  intensity, not the facet, bounds those.
* **What a request costs, and who pays.** Every request holds the
  worker, one of the system runtime's dirty I/O schedulers, two by default
  ([design-runtime.md](design-runtime.md#configuration), `+SDio`), and,
  while the kernel or Fiasco's root backend polls the mailbox, a
  CPU of the system group. The runtime charges that kernel call its
  elapsed time, at ERTS's rate of four reductions a microsecond
  (`erl_process.h:2975-2984`, with `CONTEXT_REDS` 4000 at
  `erl_vm.h:53`; the comment there says two, the code gives four), the
  rule ERTS already applies on a dirty CPU scheduler
  (`beam_common.c:160-171`) and here applied on both pools
  ([design-runtime.md](design-runtime.md), its ERTS changes). The worker reads its own
  reductions around the call and returns the difference with the
  answer, and the device service adds it to the cost its serving path
  returns with the reply. The PCIe domain's facet therefore accounts
  each `firmware` request at the time the mailbox took, up to 4,000,000
  reductions at the 1 s deadline. The `pci_bus` grant's share is
  `reductions 5000000` per `period_ns 10000000000`: one request at its
  deadline and the start's `targets` and `report` fit in one period,
  and over any run of periods the domain's requests hold the worker for
  at most about 1.25 s in 10 s, plus the one request in flight when the
  share ran out, which the facet carries as a debt. Repeated requests
  that each succeed just inside the deadline cost the domain nearly the same
  share as requests that time out. The system domain's own callers are
  charged to no facet: their rate is the poll's nine readings every 5 s
  and the line service's power cycles, and the system group's grant
  pays for them as for every other system service
  ([design-scheduler.md](design-scheduler.md#service-work), S6).
  The charge, the in-flight limit and the share are the target design,
  runtime and manifest code that is the same in both phases. On the
  stopgap the facet behaviour checks the limit in flight but admits by
  no measured share (`TODO.md`, the facets item), so the one request in
  flight holds there and the share does not: a PCIe domain that asks
  without pause keeps the worker and a system CPU busy, the sensor
  readings and the line's power cycles still each waiting behind at most
  one of its requests. That is the facets item's residual of progress
  against load, which a development build's trusted PCIe domain does
  not exercise, and this design adds nothing to work around it.
* **The device service stays live.** The worker alone waits on the
  kernel; the device service's own process only queues requests and
  hands out answers, so it answers the watchdog's liveness call within
  the period ([design-system.md](design-system.md#boot), "The
  watchdog") whatever the mailbox does. A request holds the worker and
  one of the system runtime's dirty I/O schedulers for one kernel call;
  its usual length is unmeasured ([Performance](#performance)), and its
  bound is the call's 1 s.
* **A mailbox that stops answering.** The first reading to meet it
  waits its 1 s and answers `ERX_ETIMEDOUT`; from then on every request
  of the boot answers `ERX_ETIMEDOUT` at once without touching the
  mailbox, the VL805's notification and the Bluetooth power line
  included, by the notification's rule
  ([design-bluetooth.md](design-bluetooth.md#the-power-line), "After a
  timeout"). The readings show `[timeout 1000]`, the console gets the one
  error line, and the poll goes on at no cost. A mailbox broken for one
  caller is broken for all; no consumer works around it, and the next
  boot starts afresh. The readings make that state no likelier: they do
  not cause it, they find it sooner.
* **A firmware that ignores a tag** answers without the response bit,
  so that attribute is `[unsupported]` at every poll and the others are
  unaffected. **A firmware that answers outside the interface**, with a
  parse error, an unsolicited tag first or a short answer, gives
  `ERX_EPROTO`, and that attribute is `[error]`.
* **A trial request** waits out a reading in flight, at most its
  deadline, as it waits out a notification; a reading that finds the
  trial request in flight is `{error, busy}`, and the machine resets
  before the next poll.
* **The sensor driver's crash** loses only its snapshot: its supervisor
  restarts it, the path reads `unknown` until its first poll ends, and
  the device service is untouched.
* **The device service's restart** fails the reading in flight with
  `{error, failed}`; the sensor driver asks the new one at the next row.
  A call the old worker left in the kernel finishes within its 1 s, and
  a request of the new worker that meets it answers `ERX_EBUSY`, a
  failure of that one request.
* **The firmware writes late.** A late answer after a timeout writes the
  core's own page, which nothing reads again in that boot.

## Refusals and error results

| Call | Result | When |
| --- | --- | --- |
| `erx_firmware_request` | `ERX_OK` with `n` and the answer | the answer passed every check |
| | `ERX_ENOTSUP` | a resource that names no rows, an index past its list, a platform with no rows; a response word without bit 31, other than 0 on a tag declared to take it as performed: the firmware ignored the tag |
| | `ERX_EPROTO` | a response code other than success, `0x80000001` included; a first tag other than the row's; a response length below the tag's least answer |
| | `ERX_ERIGHTS` | a resource without `CARVE` |
| | `ERX_ETIMEDOUT` | no answer within 1 s of the call's start, and every call after one in the boot |
| | `ERX_EBUSY` | another request in flight: a trial request, or a call a restarted device service's old worker left in the kernel |
| | `ERX_EWOULDBLOCK` | a call from an executor |
| `erx_devices:firmware_read(Reading)` | `{ok, Answer}` or `{error, Status}` | the kernel call's result; a `Reading` that is not a machine row of the platform is `{error, enotsup}` |
| `pci_bus:firmware(Bridge)` | `{error, busy}` | the facet's refusal of a request past the grant's one in flight, which the caller may retry after the first one's reply; a request sent while the share is spent waits in the facet's queue and then the domain's lane, as every facet's does |
| `[sensors]` | `{error, unsupported}` | no sensor driver in this runtime |
| | `{error, failed}` | a sensor driver that does not answer |
| `/proc/sensors/status` | `enoent` | outside the reader's inspect scope, as any path |

## Security

The firmware is the board's own closed binary, resident with access to
all memory ([design.md](design.md#residual-risks), "Closed firmware, and
verified boot only where secure boot is on"), so nothing here defends
against a hostile firmware. What the design defends is the boundary PL2
draws: no driver and no domain reaches the interface's other powers, the
key read, the VideoCore's memory and its code execution. That holds
because what is sent is a row of the checked record, the rows' tags are a
closed set without those powers, the gencmd text is a closed set of one
command, and the caller chooses only a row index. The replies are read as
device-written memory: by fixed offsets, each field once, into a bounded
window, and decoded in Erlang through a fuzzed decoder that echoes
nothing of their text.

`design.md`'s chokepoint row for the mailbox records this use: every
request after boot sends one row's fixed tag and arguments and reads back
at most that tag's window. The mailbox's registers stay referenced from
the same three functions, the request routine standing where the
notification's was, so the chokepoint check's list does not grow.

## Verification

**Host tests of the mailbox core**, extending the model mailbox of
[design-usb.md](design-usb.md#verification) (one that answers at once,
late or never, and can answer another buffer), with a write side that
can stay full and a record of the cache maintenance the core asks for.
Each passing case is paired with a seeded fault that makes it fail:

| Case | Seeded fault |
| --- | --- |
| a `get_temperature` row's buffer is the declared layout, word for word | the value buffer's size written as the request's alone, not the larger of request and window |
| a success answer of 8 bytes returns `n` = 8 and the two words | the copy taken from offset 0 of the value buffer's header instead of its value |
| a response length of 200 for a 64-byte window returns `n` = 64 and touches nothing past the window | `n` taken from the response length unclamped: the test's guard page faults |
| a code of `0x80000001`, a code of `0x80000002`, a first tag other than the row's and a response length below the least answer each answer `ERX_EPROTO`; a response word without bit 31 answers `ERX_ENOTSUP` | each check removed in turn; the two statuses swapped, under which the ignored tag reads `ERX_EPROTO` |
| a notification row (window 0) returns `ERX_OK` with `n` = 0, as the USB design's call does | the least answer applied to a notification as 8 |
| a set-GPIO-state row answered with a response word of 0 returns `ERX_OK`; a `get_voltage` row answered so is `ERX_ENOTSUP` | the zero-word exception applied to every tag, or to none |
| an index past the machine's rows, and a device resource asking for a machine row, are `ERX_ENOTSUP` | the root resource's list used for every resource |
| a write side that stays full gives `ERX_ETIMEDOUT` 1 s after the call's start | the deadline started at the post, so the call waits past 1 s |
| the clean before the post and the invalidate before the first read each span the buffer from its size word to its end tag | the invalidate spanning the response word alone |
| after a timeout every call answers `ERX_ETIMEDOUT` without posting | the poisoned flag cleared by a later success |

**Fuzz targets**, landing with the code: the core's answer check over
arbitrary buffer bytes and response words, which must never read outside
its page or return `n` above the window (seeded fault: the unclamped
`n`, which ASan reports); and `erx_board_sensors_core:decode/2` over
every reading and arbitrary replies, which must return a value of the
attribute's type or a status and never crash (seeded fault: the
hexadecimal parse without its eight-digit bound, which yields a value
past 32 bits that `erx_schema:validate_record/1` refuses).

**Host tests of the generator and the Erlang cores:**

| Case | Seeded fault |
| --- | --- |
| a platform record whose machine row carries a tag or an argument of its own, or names a reading `fw_reading` does not declare, fails the build | the record reader ignoring a machine row's other keys: a `soc_temperature` row with `get_voltage` builds |
| each row of the decoding table, one reply each | the id echo check removed: the mismatched-id case reads a value |
| `0x80000000` for a voltage is `unsupported`; 12 for a voltage is `{error, out_of_range}`; 0 for a clock is `{error, out_of_range}` | the voltage range's lower bound dropped; a clock's 0 taken as `unsupported` |
| `{error, enotsup}` renders `[unsupported]` and `{error, eproto}` renders `[error]` | the two statuses decoded alike |
| `changes/2` with `after_read/1`, for each span, `sticky` and `cleared_by_read`, over every pair of throttle words drawn from the eight named bits, exhaustively (256 by 256), against the table above | the clear lines dropped; the "between readings" condition reading only this poll |
| two intervals in a row each holding a transient, read as `occurred=1, current=0` twice: two lines where a read clears the bits, one where they are sticky | `after_read/1` keeping the occurred bits where a read clears them: the second interval logs nothing |
| a non-`ok` throttle reading between two equal readings logs nothing | the reference replaced by every reading |
| `erx_sensor_records` renders each status, `unknown`, `unsupported`, `{timeout, 1000}`, `{error, _}`, as V2 requires | a status rendered as 0 |

**The device service's firmware worker**, in hosted mode with a model
of the domain library's firmware call that takes its full 1 s and
records overlapping entries. A sensor poll running while the Bluetooth
line power-cycles and the bridge asks for its notification never
overlaps two calls (seeded fault: the sensor driver calling
`erx_domain_lib:firmware/2` itself, which the model sees overlap), and a
liveness call made to the device service every 100 ms through all of it
is answered within 100 ms each time (seeded fault: the device service's
own process making the call, under which a liveness answer waits up to
1 s).

**Repeated requests near the deadline**, in the same hosted setup with
the model call answering `ERX_OK` after 950 ms, just inside the
deadline. A test domain holds a `pci_bus` facet with the grant of the
Pi 4's manifest row, and four of its processes each call
`pci_bus:firmware(Bridge)` in a loop for six whole periods, which the
test counts by the account's period number, while the sensor driver
polls:

| Case | Seeded fault |
| --- | --- |
| the model never holds two of the test domain's requests, queued or in the call, at once; the processes that ask meanwhile get `{error, busy}`; each sensor reading is answered within 2 s, its own 950 ms and at most one PCIe request's | the grant's `in_flight` set to 2: the model sees two of the domain's requests, and a reading waits behind both |
| each successful request is charged at least 3,800,000 reductions in the facet's account, and the domain's successful requests over the six periods number at least 6 and at most 8, (6 x 5,000,000 + 4,000,000) / 3,800,000 | the worker answering without its reductions, and, separately, the dirty I/O pool charged one reduction a call: under each, the account charges each request under 10,000 reductions and the domain gets more than 20 requests through |
| a liveness call every 100 ms is answered within 100 ms throughout | as above: the device service's own process making the call |

**The dirty I/O charge**, an ERTS test beside OTP's `dirty_nif_SUITE`
(which asserts no reduction count): a test NIF on a dirty I/O scheduler
that sleeps 100 ms raises its caller's `reductions` by at least
400,000. Seeded fault: the one reduction a call of the dirty I/O branch
(`beam_common.c:152-159`) restored, under which the rise is under 100.

**The QEMU `virt` suite** (HVF): the shell cell reads
`/proc/sensors/status` and finds every attribute `[unsupported]` with
reporter `service`. Seeded fault: a sensor driver that leaves its
attributes `unknown` when its row list is empty fails the check, which
tells "no rows" from "not polled yet".

**Probe S2, QEMU's model**, before the `raspi4b` check is written: one
run of the `raspi4b` suite's shell cell under QEMU 11.1.3 that records
`/proc/sensors/status`, which shows for each row whether the model
answers it, and with what. The check is then written from that record:
each attribute the model answers reads a value in its range, each it
ignores reads `[unsupported]`, and the console has no line of the
warnings table. Seeded fault: the record's machine rows removed, under
which every attribute reads `[unsupported]` and the check fails for each
row the model answered. If the model answers none, the `raspi4b` check
is the `virt` check's, and the values are checked on the board alone.

**Probe S1, on the board**, before the decoder is built, as probe B1
precedes the VL805's notification
([design-usb.md](design-usb.md#the-vl805s-firmware)): on the same Pi 4,
Raspberry Pi OS's `vcmailbox` (`vcmailbox.c:80-107`, which prints every
word of the buffer) and `vcgencmd` record:

* for each reading, the raw answer words, or that the firmware ignored
  the tag, `0x00030047` for both clock ids among them;
* the text of `get_throttled`, sent with a 64-byte value buffer as the
  row sends it, and whether the firmware answers it there;
* the occurred bits' span: with a bench supply, a dip to the setting
  below and back, then `get_throttled` twice; a second reading with bit
  16 still set is `sticky`, one with it clear `cleared_by_read`;
* the supply setting at which `get_throttled` reports bit 0 set at idle,
  for the board pass below;
* `vcgencmd measure_volts`, which prints volts, against the voltage
  words, which settles their unit.

The probe's record fixes the decoder's grammar, its voltage form and
`fw_throttle`'s span, and this design is edited to match.

**The board pass**, one more step after the boot of the [Raspberry Pi 4
guide](guide/raspberry-pi-4.md#first-boot), once per
change to the sensors or the mailbox core:

1. After the prompt, `cat /proc/sensors/status`: each attribute shows a
   value, or the status probe S1 predicted for it, and `poll_duration`
   is recorded.
2. Run a CPU-bound loop on every core for 60 s, then read it again:
   `soc_temperature` is higher than at idle, and `sampled` has moved on.
   A sensor driver that kept its first snapshot would fail this step.
3. With the bench supply, set the board's supply to the setting probe S1
   found Raspberry Pi OS reporting under-voltage at, and hold it. The
   documented threshold is 4.63 V plus or minus 5 percent
   (`overclocking.adoc:380`), down to about 4.40 V, so no setting is
   taken as below it unless the board's own detector showed it so. With
   no other firmware request during the step, within 15 s, the request
   in flight, the 5 s period and the next poll's nine requests each at
   its 1 s bound, the console prints `under-voltage detected` and
   `throttle` shows `under_voltage`. Back at 5.1 V, within the same 15 s,
   `under-voltage cleared`, and `under_voltage_occurred` shown where S1
   found the bits sticky. On the board's proper supply neither line
   appears. The low supply is the step's seeded fault: a board pass that
   saw no warning under it has not tested the warning.

## Performance

A poll is nine requests every 5 s on the Pi 4, each holding the device
service's firmware worker and one of the system runtime's dirty I/O
schedulers while the kernel busy-polls the mailbox for its answer, a
CPU of the system group spent for as long as the answer takes. A
request's latency is unmeasured: no source read gives it, and FreeBSD's
10 s wait (`bcm2835_mbox.c:244-247`) bounds it only loosely.
`poll_duration` reports it on every board, and the watch list carries
the measurement ([todo-performance.md](todo-performance.md)). If a poll
turns out to cost too much, the fixes are a longer period, or one buffer
of several tags per poll, which the interface allows (wiki, lines 22-34)
at the cost of a multi-tag layout in the core. A third is a kernel call
that sleeps until the mailbox's interrupt instead of polling: it gives
the CPU back, changes nothing above the call, and leaves the charge as
it is, since the worker is held as long either way. The snapshot is a map of a
dozen small terms; `/proc` reads copy it and send no request.

## Alternatives considered

* **A read when `/proc` is read**, as FreeBSD's sysctls do. The console's
  warnings need a poll anyway, so there would be two paths; and each
  read in any domain with an inspect facet would put a request on the
  device service. One poll serves both.
* **The kernel polls and reports in the `machine` record.** It puts a
  period, a policy, and a wait of up to 1 s in the kernel's timer path,
  and the kernel would decode the firmware's values. The kernel stays a
  request routine.
* **A driver with the mailbox's page in a domain of its own.** It breaks
  PL2: that page reads the board's key and runs code on the VideoCore.
* **A raw property device for user space**, the `/dev/vcio` that
  `vcgencmd` and `vcmailbox` open (`vcgencmd.c:62-77`). It hands the
  whole interface, the key read and code execution included, to whoever
  opens it, which PL2 forbids.
* **The SoC's temperature register, read directly.** No source this
  design may read describes it (FreeBSD's `sys/arm/broadcom/bcm2835` at
  the pinned release has no thermal driver), and it gives the
  temperature alone, not the voltages, clocks or throttle state.
* **A firmware service of its own beside the device service.** A second
  service that serializes requests would need its own order with the
  device service's notifications and its own place in the watchdog's
  liveness list. The device service already is the one sender, and its
  firmware worker is part of it, not a service: it keeps no state, and
  it lives and dies with the device service by their link.
* **The device service's process making the call itself**, on a dirty
  I/O scheduler. A process running a dirty NIF cannot run its receive
  loop, so the device service would not answer the watchdog's liveness
  call for up to 1 s per request, and longer behind a queue.
* **The firmware entries on a dirty CPU scheduler**, where ERTS already
  charges by time. Dirty CPU schedulers are executors, and the call
  refuses an executor with `ERX_EWOULDBLOCK`
  ([design-runtime.md](design-runtime.md#nifs-and-blocking)).
* **Charging each request its deadline** instead of its measured time.
  The device service would need ERTS's rate of reductions to time as a
  constant of its own, a second copy of a fact ERTS owns, and a request
  of a few milliseconds would cost the PCIe domain a second's share.
* **A rate per row**, declared in the platform record. It is a second
  account beside the facet's share, and its premise fails for the
  VL805's row, which each bring-up sends again and each PCIe domain
  restart repeats; the sensor rows are the system domain's own poll,
  whose period already bounds them.
* **Refusing a second request in the device service** for each caller.
  The facet's in-flight limit already refuses it, for the one caller
  outside the system domain, before the request reaches the service.
* **A deadline for readings shorter than the watchdog's period.**
  Requests queued behind one another still add up past the period, and
  the notifications keep their 1 s; only a process that never waits on
  the kernel answers within the period whatever is queued.
* **A second kernel call for reads beside the notification's.** The
  two would share the routine, the authority, the buffer, the deadline,
  the timeout rule and the results; one call with an answer window is
  the same mechanism without the copy.
* **A direct property tag for the throttle word.** No permissively
  licensed source or Raspberry Pi documentation read for this design
  names one; if a source is found, a reading with that tag replaces the
  gencmd row and its decoder, and nothing else changes.
* **Leaving `throttle` unsupported.** It drops the console's
  under-voltage warning, the one reading a user acts on.
* **The configured clock rate, tag `0x00030002`**, in every source. It
  shows the rate last asked for, not the one running while throttled
  (wiki 375); a firmware without the measured tag shows
  `[unsupported]`, which is true.
* **Keeping the last good value after a failed reading.** It would show
  an old value as current. The snapshot shows the latest poll, and
  `sampled` says when.
* **A `ctl` to change the period or force a reading.** No consumer needs
  either.
* **The worker timing its own call** with `erlang:monotonic_time/0`
  instead of the runtime charging dirty I/O calls by elapsed time. It
  copies ERTS's rate of reductions a microsecond, a second source of
  that fact, counts the wait for a free dirty scheduler as the call's,
  and leaves every other dirty I/O call uncharged.

## References

* Raspberry Pi firmware wiki, "Mailbox property interface",
  `https://raw.githubusercontent.com/wiki/raspberrypi/firmware/Mailbox-property-interface.md`,
  fetched 2026-11-14; the wiki has no release, so the page is pinned by
  its SHA-256,
  `1197d7f52ae2ce6b731bb1ea8e1fce93df4395983629994069e71d498160dd8b`.
* Raspberry Pi `utils`, `https://github.com/raspberrypi/utils` at commit
  `eac8944a8f30a8365ea57e4d20d268baadd0eb67`, BSD-3-Clause (`LICENCE`,
  `731da956431d1a7c5073e7ee5ebe01f54e359c5339310b32f0893c6fe6507d5a`):
  `vcmailbox/vcmailbox.7`
  (`36641a244ea26a269afd8a29e4f5d40107f184e3f9be30c66cd4e99ec83287a1`),
  `vcmailbox/vcmailbox.c`
  (`8c9d8bfb9f9528f7c26e43aa6f7ac58ce09032bb9c90833f561860d9ce474217`),
  `vcgencmd/vcgencmd.c`
  (`a0acaa8fd6d61dc4fdfce1ff754123ac594b84c787d61c5e79f92ce1cd0d48ea`).
* Raspberry Pi documentation, commit
  `c6a64966af136da21a1e55551c5a395cb6987fce`, CC BY-SA 4.0:
  `documentation/asciidoc/computers/os/graphics-utilities.adoc`
  (`e3685f567e0d827fe09f25d4e78e20fb635ce9cd3c914b9287e82c7b3b77e238`),
  `documentation/asciidoc/computers/config_txt/overclocking.adoc`
  (`b19ff813e00b3b422b3a200b9d3ed1b3acffd272dcc20bf4eda8fa8a676a5b9c`).
* FreeBSD, `https://cgit.freebsd.org/src` at `release/15.1.0-p6`, the
  tree [design-usb.md](design-usb.md#references) records as commit
  `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, BSD-2-Clause:
  `sys/arm/broadcom/bcm2835/bcm2835_mbox.c`
  (`5155a952be0086a45df81895cd4fd99244ce48a322347108a756d43731cdca73`),
  `bcm2835_mbox_prop.h`
  (`5fddd7a02c70f4a014d65e5e6a3e20d9e69f77e961c035ba975572310350136f`),
  `bcm2835_mbox.h`
  (`0a25b87fdf953c1c7a6d5bc6434a446bff83c2b076127b1d3f10450dab7b1630`),
  `bcm2835_cpufreq.c`
  (`1855d5f013d9569da39ec0e560539f590c35b2139578af0551d6ded6db558738`),
  `bcm2835_firmware.c`
  (`7473dfefa39b16de0fe86e03bfbd6fab79fbb905330e0de1fc857adfeb321bc7`),
  `bcm2835_firmware.h`
  (`9dfeb72a9a56556531afab024d80d45baaba40bc07351b970f651325b3d339a7`).
  The hashes of `bcm2835_mbox.c` and `bcm2835_mbox_prop.h` equal those
  design-usb records.
* No Linux, QEMU or U-Boot source was read for this design. What QEMU's
  model answers is left to probe S2.
