# What QEMU's raspi4b model keeps of the pin controller's registers

A point-in-time record of the probe that
[design-pinctrl.md](design-pinctrl.md#verification) requires on the
model before the pin driver lands: for each kind of register
`erx_pins_bcm2711:plan/2` checks, a write of a value other than the one
read, on pins the model's console does not use, and a read back.

* **Date:** 2026-11-23.
* **Host:** Apple Silicon Mac, macOS (Darwin 27.0.0).
* **QEMU:** 11.1.3 from Homebrew (`/opt/homebrew/bin/qemu-system-aarch64`),
  machine `raspi4b`, TCG. The model's source was not read; what follows
  is what its registers answered.
* **Program:** a throwaway bare-metal probe for the model alone, not in
  erXos's tree: `qemu-raspi4b-pin-write-2026-11-23/pin_write_probe.c` in
  the history repository (`~/erxos-history`, commit `f25f128`, SHA-256
  `fef48d7810e2894e86c3bf51407d62bbb84ae3b8279da4658795638ceb1ebbb8`), built with the header probe's compiler flags and linker
  script (`test/raspi4b/header_probe.ld`) and the accessors generated from
  `hw/svd/bcm2711_gpio` and `hw/svd/mini_uart`, on erXos commit
  `364d1b90d`. The same directory holds the build and run commands
  (`run.txt`), the binary and the serial log (`serial.log`, SHA-256
  `0e733dec787b95d7eb2989dba3044a9336a79c57a8bd1543edd4fee38b66e4d3`).
* **Load:** no firmware, no BL31 and no device tree: the probe at
  `0x200000`, where CPU 0 starts through QEMU's loader; the other CPUs
  wait in `wfe`. The console is the mini UART on QEMU's second serial
  port, which the probe turns on through `AUXENB` since no firmware does.

Each field write replaces one pin's field in the word read, writes the
whole word, and reads it again.

## What the model kept

| Register kind | Written | Read back |
| --- | --- | --- |
| function select, GPFSEL2 | GPIO 21 to ALT4 (`0x00000018`), later GPIO 20 and 26 to output | as written |
| function select, GPFSEL3 | GPIO 30 to 33 to ALT3, one at a time, to `0x00000fff` | as written, `0x00000fff` |
| pull, PUP_PDN1 | GPIO 20 from down to up (`0xa0aaaaaa` to `0xa0aaa9aa`) and back | as written |
| pull, PUP_PDN2 | GPIO 34 to none, 35 to 39 to up (`0x50aaa95a` to `0x50aa554a`; 35 and 36 already read up) | as written |
| rising edge enable, GPREN0 | bit 23 set | **0: not kept** |
| falling edge enable, GPFEN0 | bit 23 set | **0: not kept** |
| asynchronous rising edge enable, GPAREN0 | bit 23 set | **0: not kept** |
| asynchronous falling edge enable, GPAFEN0 | bit 23 set | **0: not kept** |
| high level enable, GPHEN0 | bit 23 set | **0: not kept** |
| low level enable, GPLEN0 | bit 23 set | **0: not kept** |
| GPSET0 then GPCLR0, GPIO 20 an output | bit 20 | GPLEV0 bit 20 read 0, then 1 after GPSET0, 0 after GPCLR0, 1 after a second GPSET0 |

GPEDS0, read once after the six enables had been written, held 0; GPIO
23's level was not read then.

Two more readings, outside the four kinds the design names:

* **GPLEV0 does not show a pull.** GPIO 20, an input, read 0 with no
  pull, pulled up and pulled down alike.
* **GPLEV0 shows an input's latch.** GPIO 26, an input reading 0, read 1
  once GPSET0 had loaded its latch, and still 1 after it was made an
  output. On the board GPLEV shows the wire, as
  [the plan](design-pinctrl.md#the-plan) states (not re-read from the
  datasheet for this record), and an input's latch drives nothing.

## What follows for the pin driver's QEMU cases

The model keeps the function and pull fields and shows GPSET and GPCLR
at GPLEV, so the start plan's function, pull and level checks can pass
on it. It keeps no bit of the six detect enables. Design-pinctrl.md's
rule for a field the model does not keep leaves out of the model's table
the rows that need that field. No row of the Raspberry Pi 4's table
states an edge: a device row has a function, a pull and a level, and a
`gpio` row's idle state wants every enable clear, which the model always
reads. So the list of rows left out of the model's table is empty.

What the lost enables do reach is plain GPIO: a `ctl` line that asks for
an edge plans a field write the model drops, so that write answers `eio`
on the model, and no `event` file there ever reports an edge. Those are
the header design's GPIO cases
([design-header-io.md](design-header-io.md#verification)), which this
record does not settle.

Because the model's GPLEV0 shows an input's latch and not its wire, a
check that a pin's wire differs from what it drives cannot be seeded by
the model: a case that needs it seeds the register module instead, as
the design's own unset-device cases do.

## Sources

* BCM2711 ARM Peripherals, release 4 (18 January 2022), section 5.2 for
  the GPIO registers; the copy read has SHA-256
  `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78`, as
  [design-header-io.md](design-header-io.md#references) cites it.
* [research-rpi4-header-probe.md](research-rpi4-header-probe.md): the
  model's readings of the same registers before any write, which this
  probe's first readings repeat (PUP_PDN1 `0xa0aaaaaa`, the enables 0).
