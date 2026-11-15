# The Raspberry Pi 4 header probe

A point-in-time record of the first two items of the board checklist in
[design-header-io.md](design-header-io.md#verification), as far as
registers answer them: what state the firmware leaves the header's pins
and the PWM clock in, and whether GPLEV0 shows the console's receive pin
while it is in ALT5. The probe card reads them on the board, run by
hand. The tree's facts of item 1 (the header blocks' nodes, BSC5's base,
BSC2 and BSC7, the oscillator's rate) are not the probe's: the header
map's checks read them from the board's tree through `erx_dt`. The QEMU
run at the end shows that the card boots and prints; its values are the
model's, not the board's.

**Status:** the procedure and the card are ready; the board's results
below are not yet recorded. Each blank (`____`) is filled from one board
run, and the record then states that run's date and setup.

## The probe card

`make pack PLATFORM=raspi4b PROBE=header` builds the card into
`build/probe-card/raspi4b-header/` (`tools/lib/erx/header_probe.rb`):
`sdcard.img`, the card to write; `boot/`, the same files as a boot
partition; `sdcard.img.receipt.json`, their build record; and
`header-probe.bin` with `header-probe.receipt.json`, the probe program
and its own build record (its source, linker script, SVD files, pin
table, macros, compiler and linker), which the card's record also
carries under `inputs/bootable`. It is the development card of
`make pack PLATFORM=raspi4b`, with the same firmware, `config.txt`,
board tree, overlays and BL31, but its `kernel8.img` is the probe
(`test/raspi4b/header_probe.c`) in bootstrap's place, and slot A holds
no release image. The probe needs neither Fiasco nor the system image,
and sees the pins as the firmware leaves them, not what erXos's own
stack does to them afterwards.

BL31 enters the probe in EL2 with the MMU off and only CPU 0 running.
The probe reads registers only, through the accessors generated from
`hw/svd/bcm2711_gpio`, `hw/svd/cprman` and `hw/svd/mini_uart`, and
writes no register except the console's data register. Every line it
writes starts with `hp: `:

1. `erXos header probe REV`: the build, as `SourceRevision` names it.
2. `regs boot NAME = VALUE ...`: the registers below, read together at
   entry, each with its fields decoded: `PIN=FUNCTION` for a function
   select, `PIN=PULL` for a pull register, the pins whose bit is set for
   an edge or level detect enable, and the PWM clock's fields.
3. `CNTFRQ_EL0 N`: the generic timer's frequency, as the firmware and
   BL31 left it, which times the probe's phases.
4. `keys: type at the console now, for 20 seconds`, then `keys pin 15
   samples N bytes B first L low S transitions T` and `keys verdict:
   ...`: GPLEV0's bit for GPIO 15 sampled in a loop for 20 seconds while
   the console's bytes are counted (and discarded).
5. `waiting for the minute snapshot`, then `minute snapshot at N seconds
   after entry` and `regs minute ...`: the same registers read again,
   60 seconds after entry or later if the earlier phases ran long.
6. `done`. The probe then idles until the board is powered off.

A register the probe cannot read ends it early with `stopped: REASON`.
It installs no exception vectors, so a fault hangs it after its last
line, which says only roughly where.

The registers, at the CPU's addresses (the datasheet's `0x7enn_nnnn`
legacy addresses are `0xfenn_nnnn` to the CPU in Low Peripheral mode, DS
1.2.4), by the names the SVD files give them:

| Register | Address | Source |
| --- | --- | --- |
| GPFSEL0, GPFSEL1, GPFSEL2 | `0xfe200000`, `0xfe200004`, `0xfe200008` | DS 5.2, Tables 63 and 64 |
| GPREN0, GPFEN0, GPAREN0, GPAFEN0 | `0xfe20004c`, `0xfe200058`, `0xfe20007c`, `0xfe200088` | DS 5.2, Table 63 |
| GPHEN0, GPLEN0 | `0xfe200064`, `0xfe200070` | DS 5.2, Table 63 |
| PUP_PDN0, PUP_PDN1 (DS's GPIO_PUP_PDN_CNTRL_REG0 and REG1) | `0xfe2000e4`, `0xfe2000e8` | DS 5.2, Tables 63 and 90 |
| GPLEV0 | `0xfe200034` | DS 5.2, Tables 63 and 74 |
| CM_PWMCTL, CM_PWMDIV (`hw/svd/cprman`'s PWMCTL and PWMDIV) | `0xfe1010a0`, `0xfe1010a4` | not in DS; FreeBSD's offsets (Sources), in DS Tables 99 and 100's format |

The GPIO block's and the clock manager's bases are the probe's own
constants, cited to DS 5.2 and 5.4.2, since the platform record has no
`gpio` or `clocks` unit to take them from. The windows' sizes come from
the SVD files, the console's window from the platform record
(`config/platforms/raspi4b.json`), and the console's receive pin from
the pin table (`hw/pins/bcm2711.txt`, the one bank-0 pin carrying RXD1).

## Procedure

1. Wire the console adapter as
   [design-platforms.md](design-platforms.md#trying-a-card-on-a-board)
   says (ground to pin 6, receive to pin 8, transmit to pin 10, 115200
   8N1), and log it, for example `screen -L /dev/cu.usbserial-XXXX 115200`.
   Nothing else is connected to the header.
2. Build the card on the development host:
   `make pack PLATFORM=raspi4b PROBE=header`.
3. Write `build/probe-card/raspi4b-header/sdcard.img` to the microSD card
   as that section writes `sdcard.img` (`diskutil unmountDisk`, `sudo dd
   ... of=/dev/rdiskN bs=4m`, `diskutil eject`).
4. Put the card in the board, start logging, power the board.
5. When `hp: keys: type at the console now` appears, type ordinary keys
   steadily for the whole 20 seconds. The probe does not echo them.
6. Wait for `hp: done`, about 70 seconds after the probe's first line.
7. Power the board off and keep the log; the lines starting `hp: ` are
   the result.

To repeat item 2 with no key typed, power on again and type nothing:
`keys verdict: no byte received: undecided`, and `transitions` should be
0 if nothing else moves the pin.

## Setup of the board run

* **Date:** ____
* **Board:** Raspberry Pi 4 Model B, 4 GB, board revision ____
* **Console:** 3.3 V USB-serial adapter on GPIO 14 and 15, 115200 8N1,
  on ____ (host)
* **Card:** `make pack PLATFORM=raspi4b PROBE=header` at erXos commit
  ____, `sdcard.img` SHA-256 ____; the probe's first line: ____
* **Firmware:** `start4.elf` and `fixup4.dat` as `deps.lock` pins them
  at that commit: ____
* **BL31:** TF-A ____
* **Bootloader EEPROM:** build date ____

## Results on the board

* **CNTFRQ_EL0:** ____

### Pins and events at boot and a minute later (item 1)

| Register | At boot | A minute later |
| --- | --- | --- |
| GPFSEL0 | ____ | ____ |
| GPFSEL1 | ____ | ____ |
| GPFSEL2 | ____ | ____ |
| PUP_PDN0 | ____ | ____ |
| PUP_PDN1 | ____ | ____ |
| GPREN0 | ____ | ____ |
| GPFEN0 | ____ | ____ |
| GPAREN0 | ____ | ____ |
| GPAFEN0 | ____ | ____ |
| GPHEN0 | ____ | ____ |
| GPLEN0 | ____ | ____ |

* The minute snapshot was read ____ seconds after entry.
* Pins whose function or pull differs from the reset values of DS
  Tables 64 and 90, at boot: ____
* Registers that changed in the minute: ____

### The PWM clock (item 1)

| Register | At boot | A minute later | Decoded |
| --- | --- | --- | --- |
| CM_PWMCTL | ____ | ____ | src ____, enab ____, busy ____, mash ____ |
| CM_PWMDIV | ____ | ____ | divi ____, divf ____ |

* Does the firmware leave `clk_pwm` running? ____ If it does, its rate
  from the source and divisor: ____

### GPLEV0 and the console (item 2)

| Samples | Bytes received | First level | Low samples | Transitions | Verdict |
| --- | --- | --- | --- | --- | --- |
| ____ | ____ | ____ | ____ | ____ | ____ |

* With no key typed: transitions ____

## The QEMU run

Not the board's values: QEMU's `raspi4b` model runs no firmware, and its
GPIO, clock manager and generic timer are its own. The run shows only
that the card's `kernel8.img` and BL31 boot on the model and that the
probe prints every phase.

* **Date:** 2026-11-15
* **Host:** Apple Silicon Mac, macOS 27.0.1
* **QEMU:** 11.1.3, `-machine raspi4b -smp 4`, TCG, `-no-reboot`, under
  `gtimeout -k 10 150`
* **Toolchain:** Homebrew clang 23.1.3 and LLD 23.1.3
* **Card:** built by `make pack PLATFORM=raspi4b PROBE=header` from master
  `f118e7d05` with the BCM2711 SVD files and the header probe card
  applied on top, before they were committed, so the probe's first line
  named a changed tree (`n1392-...-dirty`)
* **Load:** as the raspi4b suite loads a card: the card's `bl31.bin` with
  its stub header patched (`Bl31.patch_stub`) at 0, `kernel8.img` at
  `0x200000`, the model tree the raspi4b suite gives the model
  (`build/board-tree/raspi4b/model.dtb`) at `0x8000000`, the console on
  the mini UART from a file, with 112 bytes queued as its input

What the model gave (the serial log is not kept in the tree):

* Every phase printed, in order, through `hp: done`; QEMU ran on until
  the deadline ended it, as the probe idles.
* `CNTFRQ_EL0` 54000000.
* The registers read the same at boot and at the minute snapshot, 60
  seconds after entry: GPFSEL0 to GPFSEL2 and the four edge enables 0;
  GPHEN0 and GPLEN0 0;
  PUP_PDN0 `0xaaa95555` and PUP_PDN1 `0xa0aaaaaa`; CM_PWMCTL
  `0x00000200` (SRC 0, ENAB 0, MASH 1) and CM_PWMDIV 0. With no firmware
  on the model, GPIO 14 and 15 read as inputs, not ALT5.
* Keys: 112 bytes queued on the console's input all arrived during the
  20 seconds, over 22539591 samples of GPLEV0 bit 15, which read 0
  throughout with no transition: the model does not show the console's
  receive line on GPLEV0.

## Sources

* BCM2711 ARM Peripherals, release 4 (18 January 2022), cited as DS with
  its section or table; the copy read has SHA-256
  `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78`.
* FreeBSD `release/14.3.0`, from `cgit.freebsd.org`:
  `sys/arm/broadcom/bcm2835/bcm2835_clkman.h`, line 36 (`BCM_PWM_CLKSRC
  = 0xa0`), SHA-256
  `906eb75a041232fac3abd8fae4cd9f92a9b21152123e1eb7ea620c53c12bbbcf`; and
  `bcm2835_clkman.c`, lines 71 to 74 (the divisor 4 bytes past the
  control) and line 52 (the driver matches `brcm,bcm2711-cprman`),
  SHA-256
  `928b5b4da511c1755c894a35f23729cb5f7f701b904800b4b7afd7b8fd87d579`.
  The datasheet does not place the PWM clock, so that the BCM2711's sits
  at these offsets in the general-purpose clocks' format is unverified
  until the board run shows a plausible value there.
* [design-header-io.md](design-header-io.md#verification), the checklist;
  [design-platforms.md](design-platforms.md#trying-a-card-on-a-board),
  the wiring and how to write a card;
  [research-rpi4-board-pass.md](research-rpi4-board-pass.md), the first
  board pass with the same firmware and BL31.
