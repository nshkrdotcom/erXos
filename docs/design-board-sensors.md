# Board sensors: the Raspberry Pi firmware's readings

The Raspberry Pi 4's SoC temperature, its core and SDRAM voltages, its
clock rates and its throttle and under-voltage state are known only to
the VideoCore firmware, which answers for them through the property
interface of its mailbox. This document says who asks the firmware, how
often, how its answers are checked, where the readings appear
(`/proc/sensors`), who acts on them (the console's warnings; no thermal
policy), and how QEMU's model and the board check them. It extends the
firmware notification of
[design-usb.md](design-usb.md#the-vl805s-firmware) and keeps PL2 of
[design-platforms.md](design-platforms.md#invariants): no driver reaches
the firmware.

Decisions every reader needs:

* **Every firmware request after boot is a row of the platform record.**
  The record lists the firmware requests a platform makes, each a fixed
  tag and fixed argument words, belonging to a device entry or to the
  machine. A notification (the VL805's, the Bluetooth controller's
  power) is a row whose answer is empty; a sensor reading is a row whose
  answer is two words, or a short text. One kernel call,
  `erx_firmware_request(resource (CARVE), index)`, the existing
  `erx_firmware_notify` under a name that fits both, sends a row and
  returns its answer; the caller chooses only the row.
* **The tags are a closed set the ABI declares**, each with the size of
  its request and of its answer window, so the kernel never takes a
  length or an offset from the firmware's reply, and a tag that reads the
  board's key, runs code on the VideoCore or sets a clock or a voltage
  cannot be written in a row.
* **One poll, one sender.** `erx_board_sensors`, a supervised process of
  the system domain, asks the device service for every machine row once
  every 5 s, and the device service makes the kernel calls from its one
  process, as it makes every notification. Readers of `/proc/sensors`
  read the latest poll and never cause a request.
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
`vcmailbox.7:946` and FreeBSD (`bcm2835_cpufreq.c:444, 459, 1282-1311`)
give an "offset from 1.2V in units of 0.025V". Probe S1 settles which
the board's firmware answers ([Verification](#verification)).

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
probe S1 records it.

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

### What erXos does today

Nothing reads a sensor. No erXos code reaches the mailbox at run time:
the trial request, the boot-time key read and the firmware notification
are designed ([design-platforms.md](design-platforms.md#trial-requests),
[design-usb.md](design-usb.md#the-vl805s-firmware)) but not built;
Fiasco's `rpi` platform, which asks the mailbox for memory, is not used
on the stopgap ([design-stopgap.md](design-stopgap.md)); and the only
mailbox user in the tree is the QEMU suite's framebuffer stand-in,
`test/raspi4b/firmware_fb.c`, which runs before BL31 and is never packed.

The device service's one process, which the notification's designs make
the sender of every firmware request, is not built either: `erx_devices`
is a module that hands on the domain library's catalogue and keeps no
state (`erlang/apps/erx_domain/src/erx_devices.erl:5-13`), and
`erx_domain_sup` supervises the domain service and `erx_devfs` alone
(`erx_domain_sup.erl:25-33`). That process comes with whichever of the
VL805's notification, the Bluetooth power line and this design lands
first, as the one place firmware requests are made from.

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

Non-goals: a thermal policy in erXos, since the firmware throttles by
itself and no consumer needs another; setting clocks or voltages; the Pi
5, whose record gains rows when its port checks them; the PMIC's
readings, which `vcgencmd` reaches on the Pi 4 and Pi 5 through
commands this design does not send.

## The construction: the firmware's requests are rows of the platform record

The platform record already lists, for a device entry, the notifications
that `erx_firmware_notify` sends
([design-bluetooth.md](design-bluetooth.md#the-power-line)), and that
call already serves one request at a time, against one buffer, with one
deadline and one rule after a timeout
([design-usb.md](design-usb.md#the-vl805s-firmware)). A sensor reading
differs from a notification in one thing only: its answer is wanted. So
this design does not add a second route to the firmware. It widens the
row and the call:

* **A row** is a name, what it belongs to (a device entry's path, or
  `machine`), a tag from the ABI's closed set, and the tag's argument
  words. The tag's declaration fixes the size of the request and of the
  answer window; the row cannot.
* **The call**, `erx_firmware_request(resource (CARVE), index)`, sends
  row `index` among the rows of what the resource names, a device's
  resource naming that device's rows and the root resource naming the
  machine's, and returns a status and, on success, the answer: at most
  the tag's window, never more than the firmware wrote. A notification's
  window is empty, so for the VL805 and the Bluetooth line the call is
  `erx_firmware_notify` as designed.
* **One process sends.** The device service makes every call from its
  one process; the sensor driver asks it for each machine row in turn.

Each requirement then follows:

* **PL2 holds, by construction.** The mailbox's registers stay with the
  kernel's one request routine (and the boot-time key read and the trial
  request, which are not rows). What the firmware is asked is a row of
  the record the build checked, so a domain, or the system domain's own
  code, can choose only which row; and the key read's tag, the
  code-execution and memory tags and the tags that set a clock or a
  voltage are not in the closed set, so no row can name them.
* **Bounds by construction.** The kernel lays out the buffer from the
  tag's declaration, reads the response code, the tag word and the
  response word at offsets that declaration fixes, and copies at most the
  declared window. No length, offset or tag count from the reply moves a
  read, unlike FreeBSD's walk by the value-buffer size read back
  (`bcm2835_mbox.c:358-386`).
* **Notifications keep working**, because the device service
  serializes every request, readings included, and a row that times out
  leaves the mailbox in the state the notification's design already
  defines for every caller.
* **Never fabricating** is the decoder's job, in Erlang, over a few
  words the kernel already bounded: each answer's id must echo the
  request's, each value must lie in its type's range, and the firmware's
  "not valid" values are shown as unsupported.
* **Readers cost nothing.** The poll is the only sender, so how often
  `/proc/sensors` is read changes nothing the firmware sees.

## The requests

`abi/formats/vc_property.txt` declares the property buffer's layout (its
header, a tag's header and the end tag), its codes and response bit, and
the closed set of tags erXos sends, each with what it may belong to, the
size of its request and of its answer window, and the least answer it
accepts, and whether the firmware is known to leave its response word
0. The generator computes every buffer size and offset from these
facts and validates every row of every platform record against them.

| Tag name | Tag | Belongs to | Request | Window | Least answer | Decoded as |
| --- | --- | --- | --- | --- | --- | --- |
| `get_temperature` | `0x00030006` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `get_max_temperature` | `0x0003000a` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `get_voltage` | `0x00030003` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `get_clock_rate_measured` | `0x00030047` | machine | 4 bytes: the id | 8 | 8 | `id_value` |
| `gencmd` | `0x00030080` | machine | 64 bytes: an error word of 0 and a command of the closed set, NUL-terminated and zero-padded | 64 | 4 | `gencmd` |
| the notification tags | as [design-usb.md](design-usb.md#the-vl805s-firmware) and [design-bluetooth.md](design-bluetooth.md#the-power-line) give them | device | as they give them | 0 | 0 | none |

Every tag but one requires the response word's bit 31. The exception is
the Bluetooth line's `0x00038041`, set GPIO state, whose response word
FreeBSD records the firmware leaving 0 (`bcm2835_mbox.c:362-370`): its
declaration accepts a response word of 0, as an answer of no bytes, and
still refuses a nonzero word without bit 31. That is a fact about the
tag, so it is written once, in the tag's declaration, and no caller
handles it.

The gencmd command is itself a closed set, `fw_gencmd`, of one member,
`get_throttled`, so the text a row sends is chosen from a list in the
ABI, not written in the record. The 64-byte window is erXos's choice:
`vcgencmd` uses 4100 bytes (`vcgencmd.c:45, 101`), and whether the
firmware answers `get_throttled` into a smaller buffer is for probe S1.

The Raspberry Pi 4's record, `config/platforms/raspi4b.json`, gains a
list `firmware_requests` whose machine rows are:

| Row | Tag | Argument | Attribute |
| --- | --- | --- | --- |
| 0 | `get_temperature` | 0 | `soc_temperature` |
| 1 | `get_max_temperature` | 0 | `soc_temperature_max` |
| 2 | `get_voltage` | 1 | `core_voltage` |
| 3 | `get_voltage` | 2 | `sdram_c_voltage` |
| 4 | `get_voltage` | 3 | `sdram_p_voltage` |
| 5 | `get_voltage` | 4 | `sdram_i_voltage` |
| 6 | `get_clock_rate_measured` | 3 | `arm_clock` |
| 7 | `get_clock_rate_measured` | 4 | `core_clock` |
| 8 | `gencmd` | `get_throttled` | `throttle` |

A row's name is the attribute it fills, a member of the closed set
`fw_reading` that the inspection schema's `sensors` kind is generated
from, so a row and its attribute cannot disagree; the `throttle` row
also fills `throttle_other`. The device rows, the VL805's
and UART0's, move into the same list. The rows reach the system domain
in the system manifest, beside the device records
([design-abi.md](design-abi.md#devices-and-partition-windows)), as a
record of name, belonging, tag and argument, and reach the kernel by the path
the notifications take; that path is part of the kernel section
[design-usb.md](design-usb.md#changes-to-other-designs) already lists
for `design-kernel.md`, and this design adds nothing to it.

QEMU `virt`'s record has no rows. The Pi 5's has none until its port
checks the same tags on its firmware.

## The kernel call

`erx_firmware_request(resource (CARVE), index)` keeps every clause of
`erx_firmware_notify`'s contract
([design-usb.md](design-usb.md#the-vl805s-firmware)): its authority (a
resource carries no right to pass, so only the root task holds one, and
the device service calls through the domain library), its poll of at
most 1 s with preemption points between reads, its executor refusal, its
match of the answer to its buffer, its one buffer page kept for the boot,
its rule that after one `ERX_ETIMEDOUT` every later call of the boot
answers `ERX_ETIMEDOUT` at once, and its `ERX_EBUSY` beside a request in
flight. It changes what a request is and what it returns:

1. **The rows.** A resource carved from a device entry names that
   device's rows; the root resource names the machine's. An index past
   the named list, and a resource that names neither, answer
   `ERX_ENOTSUP`.
2. **The request.** The kernel's mailbox core writes the buffer from the
   row and its tag's declaration: the buffer's size and code 0, the tag,
   the value buffer's size (the larger of the request and the window),
   a request word of 0, the row's argument bytes, zeroes to the end of
   the value buffer, and the end tag.
3. **The answer's checks**, after the answer word names the buffer, each
   field read once: the response code is `0x80000000`; the first tag's
   identifier is still the row's tag, so a response that put an
   unsolicited tag first is refused rather than searched; the response
   word has bit 31 set, or is 0 for a tag declared so; and its length, bits 30-0, is at least the tag's
   least answer. Any failed check answers `ERX_ENOTSUP`, as any answer
   other than success does today.
4. **The copy.** The call returns `ERX_OK` with `n`, the smaller of the
   response length and the tag's window, and the first `n` bytes of the
   value buffer in the caller's UTCB, the bytes after `n` in its last
   word zero. A longer response is the truncation the interface defines
   (wiki, lines 7-10), not an error. The window is at most 64 bytes,
   well inside the UTCB's 504.

The answer is device-written memory, so the core reads it through the
same once-per-field accessors and after the same cache maintenance the
notification's response word needs. Nothing past the tag's window is
read, and the window lies inside the core's own buffer page.

The core is the mailbox core of
[design-usb.md](design-usb.md#verification): C17, built for the host,
used by the stopgap's root backend and by erXos's kernel alike. On the
stopgap the backend implements the call in the root task over the
mailbox page it maps, with the same core
([design-usb.md](design-usb.md#the-vl805s-firmware), "On the stopgap").

## The sensor driver

`erx_board_sensors` is a `gen_server` in the system domain, a permanent
child of `erx_domain_sup` started after the device service's process,
and restarted by it like `erx_devfs`. It is the driver of the
firmware's sensors in the sense the system's drivers are: a supervised
Erlang process over a thin shim, here the kernel's request routine,
reached through the device service. Its decisions are in the pure core `erx_board_sensors_core`.

**The poll.** At its start the process asks the device service for the
machine's rows, `erx_devices:firmware_rows(machine)`, which the domain
library's boot view reads from the system manifest, as it reads the
placed devices. An empty list, as on QEMU
`virt`, means the process never polls and
every attribute reads `unsupported`. Otherwise it polls at once and then
5 s after each poll ends, `board_sensor_period` in
`abi/formats/vc_property.txt`, so polls never overlap and a slow one
delays the next instead of piling up. A poll asks for each row in record
order with `gen_server:send_request/2` on
`erx_devices:firmware_read(Name)`, one row at a time, the next after the
last one's answer, so the process stays free to answer the inspector
while a request is in the kernel. The device service makes the kernel
call through `erx_domain_lib:firmware(machine, Index)` and answers
`{ok, Answer}`, the answer bytes, or `{error, Status}`. A device service
that ends during a request answers that request `{error, failed}`
through `send_request`'s monitor, and the poll goes on with the next row.

**Decoding.** `erx_board_sensors_core:decode(Tag, Argument, Reply)` maps
one row's reply to an inspection value
([design-live.md](design-live.md#inspection-records)):

| Reply | Value |
| --- | --- |
| `{ok, <<Id:32/little, V:32/little>>}` for an `id_value` tag, `Id` the row's argument, `V` within the attribute's range | `{ok, V}` |
| the same with `V` `0x80000000` for `get_voltage` (wiki 476), or `V` 0 for a clock, the configured-rate tag's answer for a clock that does not exist (wiki 310), which the wiki does not state for the measured tag | `unsupported` |
| the same with `V` outside the range: below 500000 for a voltage, which is what an offset in 25 mV steps would be; 2^31 or more for a temperature | `{error, out_of_range}` |
| an `id_value` answer of other than 8 bytes, or whose `Id` is not the row's argument | `{error, malformed}` |
| `{ok, <<0:32, Text/binary>>}` for `gencmd`, `Text` holding a NUL, the bytes before it in the reply's grammar, its number at most `0xffffffff` | `{ok, Flags}` for `throttle`, and the bits outside the eight named ones as `{ok, Other}` for `throttle_other` |
| a `gencmd` answer with a nonzero error word, without a NUL, or not in the grammar | `{error, malformed}` |
| `{error, enotsup}` | `unsupported`: the firmware ignored the tag or refused the buffer |
| `{error, etimedout}` | `{timeout, 1000}` |
| `{error, ebusy}` | `{error, busy}`: a trial request was in flight |
| `{error, failed}` | `{error, failed}` |

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

**Console warnings.** `erx_board_sensors_core:changes(Previous,
Current)` compares the throttle flags of two polls and returns the lines
to log with `logger`, which reach the console and the store through the
system log ([design-log.md](design-log.md#consumers-and-backlogs)):

| Change | Level | Line |
| --- | --- | --- |
| bit 0 sets | warning | `erx_board_sensors: under-voltage detected` |
| bit 0 clears | notice | `erx_board_sensors: under-voltage cleared` |
| bit 1, 2 or 3 sets | warning | `erx_board_sensors: ARM frequency capped`, `throttled`, `soft temperature limit active` |
| bit 1, 2 or 3 clears | notice | the same with `cleared` |
| bit 16 to 19 sets while its bit 0 to 3 was clear at this poll and the last | warning | `erx_board_sensors: under-voltage occurred between readings`, and likewise for the other three |
| at the first throttle reading of the process, bit 16 to 19 set with its bit 0 to 3 clear | warning | `erx_board_sensors: under-voltage occurred before the first reading`, and likewise |
| the first `{timeout, 1000}` of the process | error | `erx_board_sensors: the firmware's mailbox does not answer; no further readings this boot` |

A throttle reading that is not `{ok, _}` changes nothing: the previous
good flags stay the reference, so a malformed reply between two equal
readings logs no clear and set. The lines are fixed text, so nothing the
firmware wrote is printed. A poll logs at most five lines, and a
restarted process may repeat the first-reading lines once per restart,
within its supervisor's intensity. Whether reading the state clears the
occurred bits is unverified: if it does, each transient between polls
logs once; if it does not, an occurrence after the first between two
polls is not seen, which the board's own behaviour allows no poll to
change. Probe S1 records which.

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
  request, readings and notifications, from its one process, so two
  never meet in the kernel and `ERX_EBUSY` arises only beside a trial
  request, as the notification's design says. A notification waits
  behind at most one reading, and a reading behind at most one
  notification or power cycle step, each at most 1 s.
* **The device service's occupancy.** Each reading holds the device
  service for one kernel call. Its usual length is unmeasured
  ([Performance](#performance)); its bound is the call's 1 s.
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
  unaffected.
* **A trial request** waits out a reading in flight, at most its
  deadline, as it waits out a notification; a reading that finds the
  trial request in flight is `{error, busy}`, and the machine resets
  before the next poll.
* **The sensor driver's crash** loses only its snapshot: its supervisor
  restarts it, the path reads `unknown` until its first poll ends, and
  the device service is untouched.
* **The device service's restart** fails the reading in flight with
  `{error, failed}`; the sensor driver asks the new one at the next row.
* **The firmware writes late.** A late answer after a timeout writes the
  core's own page, which nothing reads again in that boot.

## Refusals and error results

| Call | Result | When |
| --- | --- | --- |
| `erx_firmware_request` | `ERX_OK` with `n` and the answer | the answer passed every check |
| | `ERX_ENOTSUP` | a resource that names no rows, an index past its list, a platform with no rows; a response code other than success, a first tag other than the row's, a response word without bit 31 (other than 0 for a tag declared so), a response length below the tag's least answer |
| | `ERX_ERIGHTS` | a resource without `CARVE` |
| | `ERX_ETIMEDOUT` | no answer within 1 s, and every call after one in the boot |
| | `ERX_EBUSY` | another request in flight: only a trial request |
| | `ERX_EWOULDBLOCK` | a call from an executor |
| `erx_devices:firmware_read(Name)` | `{ok, Answer}` or `{error, Status}` | the kernel call's result; a `Name` that is not a machine row of the platform is `{error, enotsup}` |
| `[sensors]` | `{error, unsupported}` | no sensor driver in this runtime |
| | `{error, failed}` | a sensor driver that does not answer |
| `/proc/sensors/status` | `enoent` | outside the reader's inspect scope, as any path |

## Security

The firmware is the board's own closed binary, resident with access to
all memory ([design.md](design.md#residual-risks), "Closed firmware"), so
nothing here defends against a hostile firmware. What the design defends
is the boundary PL2 draws: no driver and no domain reaches the
interface's other powers, the key read, the VideoCore's memory and its
code execution. That holds because what is sent is a row of the checked
record, the rows' tags are a closed set without those powers, the gencmd
text is a closed set of one command, and the caller chooses only a row
index. The replies are read as device-written memory: by fixed offsets,
each field once, into a bounded window, and decoded in Erlang through a
fuzzed decoder that echoes nothing of their text.

This widens what the design records of the mailbox's use. `design.md`'s
chokepoint row says the notification "sends one fixed tag and value and
reads back only its status"; with this design every request after boot
sends one row's fixed tag and arguments and reads back at most that tag's
window. The mailbox's registers stay referenced from the same three
functions, the request routine standing where the notification's was, so
the chokepoint check's list does not grow. Changing the row is
[Open decision 1](#open-decisions).

## Verification

**Host tests of the mailbox core**, extending the model mailbox of
[design-usb.md](design-usb.md#verification) (one that answers at once,
late or never, and can answer another buffer). Each passing case is
paired with a seeded fault that makes it fail:

| Case | Seeded fault |
| --- | --- |
| a `get_temperature` row's buffer is the declared layout, word for word | the value buffer's size written as the request's alone, not the larger of request and window |
| a success answer of 8 bytes returns `n` = 8 and the two words | the copy taken from offset 0 of the value buffer's header instead of its value |
| a response length of 200 for a 64-byte window returns `n` = 64 and touches nothing past the window | `n` taken from the response length unclamped: the test's guard page faults |
| a response length below the least answer, a cleared response bit, a code of `0x80000001`, a first tag other than the row's: each `ERX_ENOTSUP` | each check removed in turn |
| a notification row (window 0) returns `ERX_OK` with `n` = 0, as `erx_firmware_notify` did | the least answer applied to a notification as 8 |
| a set-GPIO-state row answered with a response word of 0 returns `ERX_OK`; a `get_voltage` row answered so is `ERX_ENOTSUP` | the zero-word exception applied to every tag, or to none |
| an index past the machine's rows, and a device resource asking for a machine row, are `ERX_ENOTSUP` | the root resource's list used for every resource |
| after a timeout every call answers `ERX_ETIMEDOUT` without posting | the poisoned flag cleared by a later success |

**Fuzz targets**, landing with the code: the core's answer check over
arbitrary buffer bytes and response words, which must never read outside
its page or return `n` above the window (seeded fault: the unclamped
`n`, which ASan reports); and `erx_board_sensors_core:decode/3` over
arbitrary replies, which must return a value of the attribute's type or a
status and never crash (seeded fault: the hexadecimal parse without its
eight-digit bound, which yields a value past 32 bits that
`erx_schema:validate_record/1` refuses).

**Host tests of the Erlang cores:**

| Case | Seeded fault |
| --- | --- |
| each row of the decoding table, one reply each | the id echo check removed: the mismatched-id case reads a value |
| `0x80000000` for a voltage is `unsupported`; 12 for a voltage is `{error, out_of_range}` | the voltage range's lower bound dropped |
| `changes/2` over every pair of throttle words drawn from the eight named bits, exhaustively (256 by 256), against the table above | the clear lines dropped; the "between readings" condition reading only this poll |
| a non-`ok` throttle reading between two equal readings logs nothing | the reference replaced by every reading |
| `erx_sensor_records` renders each status, `unknown`, `unsupported`, `{timeout, 1000}`, `{error, _}`, as V2 requires | a status rendered as 0 |

**The device service's serialization**, in hosted mode with a model of
the domain library's firmware call that records overlapping entries: a
sensor poll running while the Bluetooth line power-cycles and the bridge
asks for its notification never overlaps two calls (seeded fault: the
sensor driver calling `erx_domain_lib:firmware/2` itself, which the
model sees overlap).

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
word of the buffer) and `vcgencmd` record, for each row, the raw answer
words, the text of `get_throttled`, whether it answers into a 64-byte
value buffer, whether `0x00030047` is answered, and whether a second
`get_throttled` clears the occurred bits; and `vcgencmd measure_volts`,
which prints volts, settles the voltage word's unit. The probe's record
fixes the decoder's grammar and voltage form, and this design is edited
to match.

**The board pass**, one more step in [design-platforms.md, "Trying a
card on a board"](design-platforms.md#trying-a-card-on-a-board), once per
change to the sensors or the mailbox core:

1. After the prompt, `cat /proc/sensors/status`: each attribute shows a
   value, or the status probe S1 predicted for it, and `poll_duration`
   is recorded.
2. Run a CPU-bound loop on every core for 60 s, then read it again:
   `soc_temperature` is higher than at idle, and `sampled` has moved on.
   A sensor driver that kept its first snapshot would fail this step.
3. With a bench supply at hand, power the board at 4.5 V, below the
   documented 4.63 V threshold (`overclocking.adoc:380`): within 5 s the
   console prints `under-voltage detected` and `throttle` shows
   `under_voltage`; back at 5.1 V, `under-voltage cleared`, with
   `under_voltage_occurred` still shown. On the board's proper supply
   neither line appears. The low supply is the step's seeded fault: a
   board pass that saw no warning under it has not tested the warning.

## Performance

A poll is nine requests every 5 s on the Pi 4, each holding the device
service and busy-polling the mailbox in the calling thread for its
answer. A request's latency is unmeasured: no source read gives it, and
FreeBSD's 10 s wait (`bcm2835_mbox.c:244-247`) bounds it only loosely.
`poll_duration` reports it on every board, and the watch list carries
the measurement ([todo-performance.md](todo-performance.md)). If a poll
turns out to cost too much, the fixes are a longer period, or one buffer
of several tags per poll, which the interface allows (wiki, lines 22-34)
at the cost of a multi-tag layout in the core. The snapshot is a map of a
dozen small terms; `/proc` reads copy it and send no request.

## Changes to other designs

This design lands only with these edits to the documents that own them:

| Document | Change |
| --- | --- |
| [design.md](design.md) | the mailbox chokepoint row: every request after boot is a row of the checked record whose tag is in the closed set, reading back at most that tag's window ([Open decision 1](#open-decisions)) |
| [design-usb.md](design-usb.md), [design-bluetooth.md](design-bluetooth.md), [design-pcie.md](design-pcie.md) | `erx_firmware_notify` named `erx_firmware_request`, unchanged for a row with an empty window; `erx_domain_lib:pci_firmware/1` and `device_notify/2` as uses of `erx_domain_lib:firmware/2`; the kernel section design-usb lists for design-kernel with the answer window, the root resource's machine rows and the answer's checks above |
| [design-kernel.md](design-kernel.md) | that section, when design-usb's row lands |
| [design-bluetooth.md](design-bluetooth.md), "The power line" | the power notification's answer: a response word of 0 for `0x00038041` is success (FreeBSD `bcm2835_mbox.c:362-370`), where that design takes only a set response bit; probe B-P2 confirms it on the board |
| [design-platforms.md](design-platforms.md) | the Pi 4's firmware requests; the board pass's sensors step; the sentence under "The firmware's framebuffer under QEMU" that says erXos's code never talks to the mailbox, which holds for the framebuffer alone |
| [design-system.md](design-system.md), "Devices" | the device service's `firmware_rows/1` and `firmware_read/1`, made from its one process |
| [design-abi.md](design-abi.md), `abi/manifest.txt` | the firmware request record in the system manifest; `abi/formats/vc_property.txt`; the `sensors` kind, its units and `@fw_throttle` in the inspection schema |
| [design-stopgap.md](design-stopgap.md) | the backend's implementation of the call in the root, with the answer window |
| [design-live.md](design-live.md), "The /proc tree" | `/proc/sensors/status` among the paths |

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
* **A firmware process in the system domain beside the device service.**
  A second process that serializes requests would need its own order
  with the device service's notifications; the device service already is
  the one sender.
* **A second kernel call for reads beside `erx_firmware_notify`.** The
  two would share the routine, the authority, the buffer, the deadline,
  the timeout rule and the results; one call with an answer window is
  the same mechanism without the copy.
* **The configured clock rate, tag `0x00030002`**, in every source. It
  shows the rate last asked for, not the one running while throttled
  (wiki 375); a firmware without the measured tag shows
  `[unsupported]`, which is true.
* **Keeping the last good value after a failed reading.** It would show
  an old value as current. The snapshot shows the latest poll, and
  `sampled` says when.
* **A `ctl` to change the period or force a reading.** No consumer needs
  either.

## Open decisions

1. **The mailbox chokepoint.** `design.md` records that the notification
   "reads back only its status". This design reads back each row's
   answer window. Recommendation: accept the row as given under
   [Security](#security); the functions that touch the mailbox stay
   three, and what the firmware is asked stays fixed by the checked
   record and a closed tag set. Without it, the readings cannot exist,
   and this design waits; nothing else in the tree depends on it.
2. **The throttle state through gencmd.** The only route to the throttle
   word that any source read for this design states is `vcgencmd`'s text
   command, through tag `0x00030080` with the fixed command
   `get_throttled`, which brings a short text reply and a decoder whose
   grammar probe S1 fixes. The alternatives are a direct property tag,
   which no permissively licensed source or Raspberry Pi documentation
   read here names, and leaving `throttle` unsupported, which drops the
   console's under-voltage warning. Recommendation: gencmd, with the
   command a closed set of one; a direct tag replaces the row and the
   decoder if a source for it is found. Only the throttle attribute and
   the warnings wait on this; the other readings do not.
3. **The call's name.** Renaming the accepted `erx_firmware_notify` to
   `erx_firmware_request` touches three accepted designs, by name only.
   Recommendation: rename, so the call says what it does for both kinds
   of row; keeping the old name for both costs nothing but clarity.

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
