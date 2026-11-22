# The Raspberry Pi 4's Bluetooth controller: board probes

A point-in-time record of the board probes B-P1 to B-P4 of
[design-bluetooth.md](design-bluetooth.md#board-probes), read on a
Raspberry Pi 4 Model B under Fiasco by a throwaway probe image, run by
hand. Each reading settles a provisional fact of the design: whether
`config.txt` needs `gpio=` lines for UART0's pins, which pin of the
firmware's GPIO expander powers the controller and with what polarity,
whether the off and on times bring it back, whether the controller sends
anything between power-on and `HCI_Reset`, what the firmware answers a
set-GPIO-state request with, and what the controller's ROM firmware is
and can do before the patch.

**Status:** the procedure and the image are ready; the board's readings
below are not yet recorded. Each blank (`____`) is filled from one board
run, and the record then states that run's date and setup.

## The probe image

The image is the development card of `make pack PLATFORM=raspi4b`, built
from branch `bt-probes` at commit `____` (commits marked `DIAGNOSTIC (do
not land)`), whose root task runs `liberx/backend/fiasco/bt_probe.c` once
at its start: after the firmware's mailbox is mapped, before the board
watchdog is armed and before any runtime starts, so nothing else drives
UART0, the GPIO controller or the mailbox meanwhile. Every line it writes
to the console starts with `bt probe: `. What the controller sends, and
every string of the firmware's device tree, is printed only as hex;
`xxd -r -p` turns a hex field back into bytes.

What the probe touches:

* **GPIO 30 to 33**: GPFSEL3 is read; its four fields for those pins are
  set to ALT3 only when they are not already, and the write is read back.
* **UART0**, the PL011 at `0xfe201000`, through a window of its own
  0x200 bytes, so UART3, the host link at `0x600` of the same page, is out
  of reach; 115200 baud from the record's 48 MHz clock (IBRD 26, FBRD 3),
  8N1, RTS/CTS flow control, every interrupt masked, so line 153 sees
  nothing from it. Each step reprograms it, which empties both FIFOs. It
  is left disabled.
* **The expander pin** `128 + P`, where P is the second cell of the one
  `-gpios` property of a child of `/soc/serial@7e201000` whose phandle
  names a node compatible with `raspberrypi,firmware-gpio`
  (FreeBSD's `raspberrypi_gpio.c:66`); with no such property, or more
  than one, nothing is power-cycled. Requests use the tags
  `0x00038041` (set: pin, state) and `0x00030041` (get: pin; answer pin
  word and state), FreeBSD's `bcm2835_firmware.h:143-170`. At the end
  the pin is set to the state that matches the start: on if the
  controller answered the first `HCI_Reset`, else off (and off when the
  controller answers neither end reset). When the on-state stays
  unknown, to the first get's state word translated by what the gets after
  each set showed it means (`get-reads-as-set` on the `B-P2 on-state`
  line); without that, the pin stays at 0 and a `restore skipped` line
  says so.

Sources read: FreeBSD releng/15.1 `95719d8a895b`,
`sys/arm/broadcom/bcm2835/bcm2835_firmware.h` (SHA-256
`9dfeb72a9a56556531afab024d80d45baaba40bc07351b970f651325b3d339a7`) and
`sys/arm/broadcom/bcm2835/raspberrypi_gpio.c` (SHA-256
`ad34506dd6f69144bc4bfb3bfb00fb87b6c327ad5fe30ae03ee80437e3a79224`);
every HCI value from `abi/formats/bluetooth.txt`.

## The run

* **Date:** ____
* **Board:** Raspberry Pi 4 Model B, ____ GB, revision ____
* **Firmware:** `start4.elf` ____ (the card's), board tree ____
* **Image:** commit ____, `build/production-image/raspi4b/boot`
* **Console:** the mini UART on GPIO 14 and 15, 115200 baud, logged to
  ____

The run takes about 5 s before the root goes on, plus up to 60 s for
B-P4's connection window. B-P4 needs a phone or another host scanning for
BLE devices (for example nRF Connect) and connecting to `erxos-probe`, or
the controller's address of B-P3, within that window.

## B-P1: UART0's pins at erXos's start

The line `bt probe: B-P1 gpfsel3 W fsel30 A fsel31 B fsel32 C fsel33 D`
gives each pin's function code: 7 is ALT3 (CTS0, RTS0, TXD0, RXD0); 0 is
input, 1 output, 4/5/6 ALT0-2, 3 ALT4, 2 ALT5. A line
`B-P1 set alt3 ...` follows only when the probe had to set them.

| Reading | Value |
| --- | --- |
| GPFSEL3 at start | ____ |
| GPIO 30 / 31 / 32 / 33 function | ____ / ____ / ____ / ____ |
| Set by the probe (readback) | ____ |

**Feeds:** all four 7: the firmware leaves UART0 on its pins and
`config.txt` needs nothing. Otherwise `config.txt` gains a `gpio=30-33=a3`
line (with the pulls the board needs), as it has for UART3's pins.

## B-P2: the controller's power

### Before any power request

| Reading | Line | Value |
| --- | --- | --- |
| CTS as UART0 opens (1: the controller asserts it) | `B-P2 uart0 open ... cts` | ____ |
| Bytes in the first 100 ms | `B-P2 idle rx` | ____ |
| `HCI_Reset` answered, status, time | `B-P2 reset-at-start` | ____ |

**Feeds:** an answer means the firmware leaves the controller powered,
and the bring-up's first power cycle turns off a running controller; no
answer means the power line starts off.

### The expander pin from the device tree

| Reading | Line | Value |
| --- | --- | --- |
| Child node and property (hex, decoded) | `B-P2 dt child ... property ...` | ____ |
| Its cells: phandle, pin, flags | `... cells` | ____ |
| Points at the firmware expander | `... expander` | ____ |
| The expander's `gpio-line-names` (decoded) | `B-P2 dt expander gpio-line-names` | ____ |
| The name at pin P | | ____ |
| `#gpio-cells` | | ____ |
| Candidates, pin, flags | `B-P2 dt candidates` | ____ |

**Feeds:** the pin `128 + P` of UART0's two notifications in the
platform record, and the polarity the flags cell states (that bit 0 set means
active-low is the common GPIO binding as recalled, unverified here; the
power phases below settle the polarity on the board).

### The power phases

Each phase sets the pin, gets it back, holds for 500 ms collecting what
arrives, then sends `HCI_Reset` and waits 500 ms for its answer. Each
mailbox request has one line `B-P2 mbox set|get pin N ... status S code
C indicator I value V0 V1 ms T`: S is the routine's status (0, or a
negative erXos status: the answer check refuses a response word without
bit 31 even where the design takes 0 as performed), C the buffer's
response code (0x80000000 on success), I the tag's raw response word,
V0 the first value word (the pin word, 0 on success per FreeBSD), V1 the
state word of a get.

| Reading | Value |
| --- | --- |
| First get (before any set): I, V0, V1 | ____ |
| Set 1: I, V0; get after: V1 | ____ |
| Bytes in the 500 ms after set 1 | ____ |
| `HCI_Reset` answered after set 1 | ____ |
| Set 0: I, V0; get after: V1 | ____ |
| Bytes in the 500 ms after set 0 | ____ |
| `HCI_Reset` answered after set 0 | ____ |
| On-state (`B-P2 on-state`) | ____ |
| The get reads as the set value (`get-reads-as-set`) | ____ |
| Cycle, 300 ms off then on: bytes before `HCI_Reset` | ____ |
| Cycle: `HCI_Reset` answered, time | ____ |
| Round trip of one mailbox request (ms) | ____ |

**Feeds:**

* the on-state is the polarity of UART0's notification index 1 (on) and
  index 0 (off);
* the cycle's answer settles whether Zephyr's 300 ms off and 500 ms on
  are enough at 115200, or the times need lengthening;
* bytes before `HCI_Reset` after power-on (a vendor event, or noise)
  decide whether the line service's reset must drop what arrives before
  its `HCI_Reset`;
* the raw response word I settles the tag's declaration: 0 confirms
  FreeBSD's account that the firmware leaves it unset, bit 31 set means
  the firmware answers it normally;
* the get after each set shows whether the get's state word reads the
  level as set or inverted (FreeBSD's `rpi_fw_gpio_pin_get` inverts it).

## B-P3: the controller before the patch

| Reading | Line | Value |
| --- | --- | --- |
| `HCI_Reset` before the reads | `B-P3 reset` | ____ |
| Read Local Version, from the status on | `B-P3 local-version return-from-status` | ____ |
| HCI version / subversion | | ____ / ____ |
| LMP version / manufacturer / subversion | | ____ / ____ / ____ |
| Read BD_ADDR, from the status on (little-endian) | `B-P3 bd-addr return-from-status` | ____ |
| The address as written | | ____ |

The return parameters after the status are, in order: HCI version (1
byte), HCI subversion (2), LMP version (1), manufacturer (2), LMP
subversion (2), each little-endian; the address is 6 bytes, least
significant first (as `erlang/apps/erx_bt/src/erx_hci.erl` decodes them,
its `return/2` for `read_local_version` and `read_bd_addr`).

**Feeds:** the manufacturer the patch row names and the ROM's versions,
which the after-patch reading (with the patch loaded, a later run) is
compared against; an address of the ROM's default rather than the board's
own shows whether the bring-up must set the address itself.

## B-P4: advertising on the ROM firmware

The probe sets the event masks (LE meta, disconnection complete, hardware
error; LE connection complete), connectable undirected advertising every
100 ms on all channels from the public address, with the flags and the
name `erxos-probe`, enables it, and waits 60 s for an LE Connection
Complete. Each command has its line; then
`B-P4 connected X ms T events N event 0x3e params ...` (params: subevent,
status, handle (2, little-endian), role, peer address type, peer address
(6), interval, latency, timeout (2 each), clock accuracy, as `erx_hci.erl`
decodes LE Connection Complete in `le_event/2`). After a connection the probe
waits 2 s and resets the controller, which drops it.

| Reading | Value |
| --- | --- |
| Each command's status | ____ |
| Seen by the phone (name, address) | ____ |
| Connected, after (ms) | ____ |
| LE Connection Complete parameters | ____ |
| Hardware error events | ____ |

**Feeds:** advertising and a connection on the ROM say the patch is not
needed for Stage 1; a refusal or a hardware error says the patch is a
prerequisite of every stage.

## End

The last lines are `bt probe: end reset ...`, the set that restores the
pin, and `bt probe: end: uart0 disabled`; the boot then continues as
usual (`erx: root task: ...`), and the host link and the console work as
on any boot.

| Reading | Value |
| --- | --- |
| End reset answered | ____ |
| Pin restored to | ____ |
| Boot reached the shell afterwards | ____ |
