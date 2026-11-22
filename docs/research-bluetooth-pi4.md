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

**Status:** B-P1 and B-P2 are recorded from board runs 1 to 3
(2026-11-22), which agree. B-P3 and B-P4 are pending: in runs 1 to 3
the controller answered every `HCI_Reset` and the vendor download
minidriver, and no standard command (below); run 4's image tests whether
the level of its CTS at power-up puts it in a download mode. A blank
(`____`) is a reading still to come.

## The probe image

The image is the development card of `make pack PLATFORM=raspi4b`, built
from branch `bt-probes` (run 1: commit `b0fbfb889`; commits marked `DIAGNOSTIC (do
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

Run 1:

* **Date:** 2026-11-22
* **Board:** Raspberry Pi 4 Model B, ____ GB, revision ____
* **Firmware:** `start4.elf` ____ (the card's), board tree ____
* **Image:** run 1 commit `b0fbfb889`, run 2 commit `89c9a6b4b`, run 3
  commit `9a3e427eb` (branch
  `bt-probes`), `build/production-image/raspi4b/boot`,
  built on the Apple Silicon macOS development host with Homebrew LLVM
* **Console:** the mini UART on GPIO 14 and 15, 115200 baud; the probe's
  lines are kept in the separate history repository at
  `pi4/2026-11-22-bt-probes/bt-probe-run1.txt`, `bt-probe-run2.txt` and
  `bt-probe-run3.txt`

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
| GPFSEL3 at start | `0x00000000` |
| GPIO 30 / 31 / 32 / 33 function | 0 / 0 / 0 / 0 (input) |
| Set by the probe (readback) | `0x00000fff` (`0x00000fff`) |

**Feeds:** all four 7: the firmware leaves UART0 on its pins and
`config.txt` needs nothing. Otherwise `config.txt` gains a `gpio=30-33=a3`
line (with the pulls the board needs), as it has for UART3's pins.

**Run 1:** the firmware leaves GPIO 30 to 33 as inputs, so `config.txt`
needs `gpio=` lines for them (or the bring-up sets ALT3 itself). Set to
ALT3, UART0 carried `HCI_Reset` and its answer at once.

## B-P2: the controller's power

### Before any power request

| Reading | Line | Value |
| --- | --- | --- |
| CTS as UART0 opens (1: the controller asserts it) | `B-P2 uart0 open ... cts` | 0 at the open (FR `0x90`), 1 from the next read on (FR `0x91`) |
| Bytes in the first 100 ms | `B-P2 idle rx` | 0 |
| `HCI_Reset` answered, status, time | `B-P2 reset-at-start` | yes, 0x00, 5 ms (`04 0e 04 01 03 0c 00`) |

**Feeds:** an answer means the firmware leaves the controller powered,
and the bring-up's first power cycle turns off a running controller; no
answer means the power line starts off.

### The expander pin from the device tree

| Reading | Line | Value |
| --- | --- | --- |
| Child node and property (hex, decoded) | `B-P2 dt child ... property ...` | `bluetooth`, `shutdown-gpios` |
| Its cells: phandle, pin, flags | `... cells` | `0x0000000a`, 0, `0x00000000` |
| Points at the firmware expander | `... expander` | yes |
| The expander's `gpio-line-names` (decoded) | `B-P2 dt expander gpio-line-names` | `BT_ON`, `WL_ON`, `PWR_LED_OFF`, `GLOBAL_RESET`, `VDD_SD_IO_SEL`, `CAM_GPIO`, `SD_PWR_ON`, and an empty eighth |
| The name at pin P | | `BT_ON` |
| `#gpio-cells` | | 2 |
| Candidates, pin, flags | `B-P2 dt candidates` | 1, 0, `0x00000000` |

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
| First get (before any set): I, V0, V1 | `0x80000008`, 0, 1 |
| Set 1: I, V0; get after: V1 | `0x00000000`, 0 (status -12: the answer check refuses the word); 1 |
| Bytes in the 500 ms after set 1 | 0 |
| `HCI_Reset` answered after set 1 | yes, 6 ms |
| Set 0: I, V0; get after: V1 | `0x00000000`, 0 (status -12); 0 |
| Bytes in the 500 ms after set 0 | 0 |
| `HCI_Reset` answered after set 0 | no; FR `0x18`: the command stays in the transmit FIFO with CTS deasserted |
| On-state (`B-P2 on-state`) | 1 |
| The get reads as the set value (`get-reads-as-set`) | yes |
| Cycle, 300 ms off then on: bytes before `HCI_Reset` | 0 |
| Cycle: `HCI_Reset` answered, time | yes, 1 ms |
| Round trip of one mailbox request (ms) | 1 to 2 |

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

**Run 1:**

* the firmware leaves the controller powered: the first `HCI_Reset`
  was answered before any power request;
* the enable line is expander pin 0, named `BT_ON`, so the request's pin
  word is 128; it is active high (on is state 1), and the device tree's
  flags cell is 0;
* 300 ms off and 500 ms on bring the controller back at 115200: the
  cycle's `HCI_Reset` was answered in 1 ms;
* the controller sends nothing between power-on and `HCI_Reset`;
* the set tag's response word is 0, as FreeBSD records, so the tag's
  declaration must take 0 as performed, as the design has it; the
  current answer check refuses it (status -12). The get tag answers
  normally (`0x80000008`, 8 bytes), its pin word 0;
* the get's state word reads as the level set, not inverted as
  FreeBSD's `rpi_fw_gpio_pin_get` reports it.

## B-P3: the controller before the patch

**Pending.** In run 1 every `HCI_Reset` was answered within 1 to 6 ms,
each sent right after the probe reprogrammed UART0. Read Local Version,
Read BD_ADDR and Set Event Mask, each sent about 2 ms after a reset's
Command Complete without reprogramming, got no byte in 500 ms; FR stayed
`0x91` (CTS asserted, both FIFOs empty), so the bytes left. The framing
matches NetBSD's `uart_send_cmd` (`btattach.c:373-375`, trunk
`5cebe14c1559`, SHA-256
`58c3d467335cfb0e2791ef185ca232326f9289e570df887c1387c77df3e92b74`):
indicator `0x01`, opcode little-endian, length. Run 2's image (commit
  `89c9a6b4b`) tries
Read Local Version after `HCI_Reset` at 0, 50, 200, 500, 1000 and
2000 ms, then with no reset, then with UART0 reprogrammed before each
command, then with RTS held asserted by software instead of following
the receive FIFO (lines `B-P3 try N ...`, each with UARTCR as `cr`),
and reads B-P3 and B-P4 by the first that answers
(`B-P3 first answering try N`).

**Run 2:** no try answered. Each try's `HCI_Reset` was answered in 1 ms
(`04 0e 04 01 03 0c 00`); each Read Local Version (`sent 4/4`) got no
byte in 500 ms, FR `0x91` throughout:

| Try | Before Read Local Version | UARTCR | Answered |
| --- | --- | --- | --- |
| 0-5 | `HCI_Reset`, then 0, 50, 200, 500, 1000, 2000 ms | `0xc301` (RTSEn, CTSEn) | no |
| 6 | no reset | `0xc301` | no |
| 7 | `HCI_Reset`, UART0 reprogrammed before the command | `0xc301` | no |
| 8 | `HCI_Reset`, RTS held asserted by software | `0x8b01` (RTS, CTSEn) | no |

So neither the delay after a reset, nor our RTS mode, nor UART0's state
between commands decides it: the controller answers `HCI_Reset` and not
Read Local Version. Run 3's image (commit `9a3e427eb`) sends, each after a
fresh `HCI_Reset`, Read Local Name (`0x0c14`, what NetBSD's
`init_bcm43xx.c:65` sends first), Read Local Version, Read BD_ADDR,
Read Buffer Size, and last the vendor download minidriver (`0xfc2e`);
it logs the bytes written to UARTDR (`tx`), every byte of the 2 s
after each command, and whether an `HCI_Reset` sent right after is
still answered (lines `B-P3 listen NAME ...` and
`B-P3 listen reset-after ...`). A minidriver whose following reset goes
unanswered gets a power cycle before the end reset.

**Run 3:** the controller answered every `HCI_Reset`
(`04 0e 04 01 03 0c 00`, 1 to 2 ms) and the vendor download minidriver,
and sent no byte in the 2 s after any standard command. Every reset
after a command was answered, so it was neither wedged nor deaf: it took
each command off the line and did not answer it. No receive error was
flagged and FR read `0x91` (CTS asserted, both FIFOs empty) throughout:

| Command | tx | rx in 2 s | Reset after |
| --- | --- | --- | --- |
| Read Local Name | `01 14 0c 00` | none | answered, 1 ms |
| Read Local Version | `01 01 10 00` | none | answered, 2 ms |
| Read BD_ADDR | `01 09 10 00` | none | answered, 1 ms |
| Read Buffer Size | `01 05 10 00` | none | answered, 2 ms |
| Download minidriver (`0xfc2e`) | `01 2e fc 00` | `04 0e 04 01 2e fc 00` | answered, 1 ms |

The power phases and the end matched runs 1 and 2: the reset with the
pin at 1 was answered, the one with the pin at 0 was not in 500 ms, with
FR `0x18` (CTS deasserted, the reset's bytes held in the transmit FIFO,
so CTS flow control works both ways), the end reset was answered in
1 ms and the pin went back to 1.

What the two answered commands share: Infineon's "AIROC HCI firmware
download" user guide (002-32056 Rev. *B, 3.1 to 3.3; fetched 2026-11-22
from `infineon.github.io/btsdk-docs/BT-SDK/AIROC-HCI-Firmware-Download.pdf`,
SHA-256
`a9c593bdd184c673eeb0df2b76a70cd86cfed6d7f1e9fbbd001f4f38254b8e60`)
says its controllers' boot code reads the chip's CTS, the host's RTS,
when reset is released. LOW there gives the autobaud state, download
mode, in which the `HCI_Reset` handshake is answered and "read, write,
and launch commands" are accepted; HIGH gives the stored configuration
and "a mode ready to accept all HCI commands", or autobaud again when no
configuration is stored. Zephyr v4.2.0's `AIROC_AUTOBAUD_MODE` help
(`drivers/bluetooth/hci/Kconfig.infineon:199-212`, SHA-256
`faaf674fd582dc4925cf873200b1f01bb6e24bac6c18511ac67e16d1e1310f90`)
adds that the baud rate command is not taken in download mode before the
minidriver. The guide is written for Infineon's controllers with flash,
not the BCM43455, so whether the 43455's ROM boots that way is
unverified. Every power-up of runs 1 to 3 had UART0 open with RTSEn and
an empty receive FIFO, so RTS0 was LOW, asserted, when the pin went on;
at the firmware's own power-up GPIO 31 was an input (B-P1), at a level
not recorded. Nothing read says the ROM needs the patch file before it
answers standard commands: NetBSD's `init_bcm43xx.c:105-113` (trunk
`5cebe14c1559`) sends Read Local Name right after `HCI_Reset` and
before any patch, and names the patch file from its answer.

Run 4's image (commit `827dd2fc5`) logs CTS0's and RTS0's levels from
GPLEV0 (`cts0-level`, `rts0-level`: 1 HIGH, deasserted; 0 LOW,
asserted) at the start and on every line, and powers the controller up
twice, 300 ms off and 500 ms on with RTS0 held as the table says and
every byte of the 500 ms logged (`during`), nothing sent, then RTS back
to following the receive FIFO and 100 ms more logged (`released`)
(`try A power-up ...`, `try B power-up ...`). Each try sends one command,
logs the bytes written and every byte of the next 2 s
(`try NAME ...`), and is followed at once by an `HCI_Reset`
(`try reset-after ...`), so every try after a power-up's first goes
right after a fresh reset:

| Try | Power-up, RTS0 | Command | What it decides |
| --- | --- | --- | --- |
| A1 | LOW (as runs 1 to 3) | Read Local Version, first, no reset before | whether a fresh ROM answers before any reset |
| A2 | LOW | Write Scan Enable, scans off (`01 1a 0c 01 00`) | whether an answer as short as the reset's, a status alone, gets out: length or mode |
| A3 | LOW | Read Local Supported Commands (`01 02 10 00`) | another standard command, the list the ROM would claim |
| A4 | LOW | Update UART Baud Rate to 115200, the rate in use (`01 18 fc 06 00 00 00 c2 01 00`) | a vendor command download mode does not take; answered means a mode that takes vendor configuration |
| A5 | LOW | Launch RAM to address 0 (`01 4e fc 04 00 00 00 00`), the guide's reboot, then Read Local Version, then after a reset Read Local Version | whether download mode takes the launch, and whether a reboot with CTS still asserted stays in it |
| A6 | LOW, raised HIGH once the launch has left, held 500 ms | the same launch, then the same two Read Local Versions | whether a software reboot with CTS deasserted reaches the normal mode, with no power cycle |
| B1 | HIGH through the power-up | Read Local Version, first | whether the ROM boots ready for every command with CTS deasserted |
| B2 | HIGH | Read Local Version after a reset | the same after the reset handshake, which decides B-P3 and B-P4 |
| B3 | HIGH | Write Scan Enable | a status-only answer in that mode |
| B4 | HIGH | Read BD_ADDR | the ROM's address |

The CTS hypothesis holds if A1 to A3 go unanswered and B1 or B2 is
answered, with `rts0-level 1` in B's `during` fields. If B2 is
answered, the image goes on to the B-P3 reads and B-P4's advertising in
that mode. If nothing in B is answered either, the level of CTS is not
what selects the mode on this controller, and the next question is
whether its ROM serves standard commands at all before the patch.

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

**Pending:** run 1 stopped at Set Event Mask, unanswered.

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
| End reset answered | yes, 1 ms (run 1) |
| Pin restored to | 1, on (run 1) |
| Boot reached the shell afterwards | ____ |
