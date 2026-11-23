# Pin control: one table of pins, one driver per pin controller

A system-on-chip has more signals than pins. A **pin controller** is the
device whose registers say, for each pin, which block of the chip drives
it (its **function**), whether a pull resistor holds it up or down, and,
for a pin that software drives, its direction and level. A UART whose
pins are still plain inputs sends nothing, so some code must write those
registers before a driver uses its device.

This document says where a board's pin assignments are written down,
which code may write a pin controller's registers, when each pin is set,
how a driver changes its own pins at run time, how plain GPIO is served,
and what a user sees. It turns the Raspberry Pi 4's header map
([design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header))
into a table of every pin of every board, and it puts one driver in the
place of three writers: the root's boot write, the planned GPIO driver,
and RP1's function driver.

Decisions every reader needs:

* **One table per board is the only statement of a pin fact.** The
  board's **pin table** has one row per pin. A row gives the pin one
  **owner** (a device, plain GPIO, the firmware, or nobody) and, for a
  device's pin, a **setting** for each named **state** of that device.
  The build checks the table whole and packs it into the manifest. Two
  owners of one pin cannot be written: a pin has one row.
* **One driver per pin controller is the only writer.** `erx_pins` runs
  in the domain that holds the pin controller, and nothing else has a
  name for a pin register. At its start it sets the pins of every device
  that has one state. Afterwards it writes only for a state name or a
  GPIO request that the table and the asker's grant allow.
* **Defaults need no request.** A device with one state, `default`, is
  put in it when the pin driver starts, whether or not the device is
  driven, and there is no claim protocol between drivers.
* **A configuration boots only with its devices' pins set.** A pin the
  start cannot set is logged, and nothing that would use its device
  starts: the system release boots the larger of its two
  configurations, normal and rescue, whose devices are all set, and
  does not boot when rescue's own are not.
* **Every write is planned whole, applied, and checked by planning
  again.** A pure function takes the registers as read and the settings
  wanted and returns the register writes, or a refusal that writes
  nothing. A pin is set when the plan over a new reading has nothing
  left to write for it.
* **A driver never sends a function, a pull or a level.** It selects a
  state by name, and the table says what the state means. A reset line,
  a power enable or a signalling voltage is a second state of the device
  that owns the pin. A state stays until another is selected.
* **The pin driver keeps no record of a device's state.** The state a
  device is in is read from its pins' registers, so a restart of the pin
  driver loses nothing. No start of the pin driver, the first or a later
  one, writes a pin of a device whose driver selects states.
* **The console's pins are the firmware's.** The kernel prints before
  any driver runs, so the firmware sets the console's pins. The build
  checks that the rows the table gives the console are the pins the
  firmware's own setting sets, and no such row reaches the pin driver.
* **The firmware's device tree is never read for pins.** A pin's owner
  is authority, and authority is what the build proves. Where a board
  has too many wired pins to write by hand, the build reads them from
  the tree it compiles; they enter as rows and pass the same checks
  ([Rows from a board's tree](#rows-from-a-boards-tree)).
* **Files.** `/dev/gpio` for plain GPIO pins, `/dev/pins` for a device's
  states, and `/proc` for every pin's owner, state, wanted setting and
  the setting its registers actually hold.

## What is matched

### What other systems do

| System | Where pin facts come from | Who writes, and when | Two claims on one pin |
| --- | --- | --- | --- |
| FreeBSD releng/15.1 | the device tree at boot: a device's `pinctrl-N` names groups, each decoded by the controller's own driver (`fdt_pinctrl.c:37-58`) | the controller's driver, at its attach, applies state 0 of every enabled node (`:126-155`); other states when a driver asks by name (`:60-80`) | not detected; groups are applied pin by pin and may be left half applied (`bcm2835_gpio.c:1243-1310`) |
| NetBSD 10, OpenBSD 7.8 | the same | NetBSD's bus before each device's attach (`fdtbus.c:454-494`); OpenBSD's drivers themselves, at 73 call sites | not detected by either (OpenBSD's `ofw_pinctrl.c:79-97`); NetBSD's GPIO release forces input and loses the function (`bcm2835_gpio.c:950-957`) |
| Linux 6.12 (documentation only) | the device tree, or board tables | the core selects `default` before a driver's probe; a driver selects other states | first come, first served, refused at run time; GPIO and function claims are coupled by a per-driver flag |
| Zephyr 4.3.2 | the device tree, compiled into constant tables (`pinctrl.h:53-75`) | each driver applies a whole named state (`common.c:9-22`) | not detected; ownership is a naming convention (`index.rst:424-430`) |
| Hubris | one build-checked file for tasks, registers and pins | drivers ask the one task that maps the GPIO block, over IPC | checked at build for interrupt pins only (`build/stm32xx-sys/src/lib.rs:164-166`); the authors call run-time access "loosey-goosey" (`drv/stm32xx-sys/src/main.rs:24-29`) |
| Embassy, rp-hal | chip metadata, generated | a peripheral's constructor takes its pins by value and its drop releases them (`usart/mod.rs:1080-1093`) | cannot compile, within one program |
| 9front | compiled tables | kernel drivers and any writer of `#G/gpio/ctl` | not detected; an unknown word in `ctl` succeeds silently (`devgpio.c:559-584`) |
| sDDF 0.7.0 (design only) | a table generated from the device tree at build | a pin driver run once before the others; no run-time interface (`design.tex:2484-2547`) | not described |
| QNX 8.0 | board startup code | `init_pinmux()` before any resource manager | not described |

What erXos takes: a state is a whole, named set of settings, selected by
name (Zephyr, Hubris's SPI routings), which stays until another is
selected (FreeBSD, Zephyr); pin ownership is checked when the
description is built (Hubris, Embassy); a plain GPIO pin goes back to
rest when its holder ends (Embassy's drop); state is a file to read and
control a file to write (9front). What it avoids, each seen above: no
ownership at all; two writers of one register field; a group left half
applied; permissive `ctl` parsing; and a device tree, which firmware
supplies, as the authority over who owns a pin.

### The boards

**Raspberry Pi 4.** The BCM2711's GPIO block is pin controller and GPIO
controller in one page, with no lock
([design-header-io.md](design-header-io.md#the-hardware)). Three sets of
pins need setting:

* The header's bus pins and the host link's, which the firmware sets
  today from `config.txt`'s `gpio=` lines.
* UART0's four pins to the Bluetooth controller, GPIO 30 to 33 in ALT3.
  The firmware leaves GPIO 30 and 31 inputs whatever a `gpio=` line
  asks: GPFSEL3 read `0x00000fc0` at every boot of four board runs, and
  the controller answered only after erXos wrote `0x00000fff`
  ([research-bluetooth-pi4.md](research-bluetooth-pi4.md#2026-11-23-the-firmware-leaves-uart0s-flow-control-pins-unset)).
* The Wi-Fi chip's SDIO lines, GPIO 34 to 39 in ALT3, the clock with no
  pull and the other five pulled up
  ([research-wifi-pi4.md](research-wifi-pi4.md#f1-and-f4-what-the-tree-states-board-probe-facts-not-settled-here),
  fact 33). Whether the firmware sets them is that design's probe item;
  a writer of function fields alone could not set the pulls.

**Raspberry Pi 5.** Three pin controllers. The BCM2712 has a main and an
always-on controller, each a device apart from the GPIO banks that drive
the same pins; RP1, behind PCIe, has its own for the 40-pin header and
for its Ethernet and USB. In the Raspberry Pi firmware distribution's
tree (tag 1.20260915, read through a clean-room facts record) the
enabled devices with pin groups are: the SD slot (pulls on five pads,
and card detect on always-on GPIO 5 with a pull-up), an SPI controller
(GPIO 1 to 4), the Bluetooth UART (GPIO 24 to 27), the Wi-Fi SDIO
(GPIO 30 to 35), two plain GPIO lines to the radio chips (GPIO 28, the
Wi-Fi chip's power enable, and GPIO 29, the Bluetooth controller's
shutdown), the power button (GPIO 20), and RP1's USB (GPIO 42 and 43 in
function `vbus1`). The groups name pins
and functions by strings (`gpio24`, `uart0`, `bias-pull-up`). No binding
document for the BCM2712's or RP1's controller exists at the pinned
commit, so the full list of function names, and the BCM2712's register
encoding of them, are unverified. RP1's function table is public
([research-rp1-clocks.md](research-rp1-clocks.md#6-pads-function-select-and-the-gpio-setup-found--not-found)).
RP1's GPIO 32 is the Ethernet PHY's reset, a line software drives
([design-rp1.md](design-rp1.md#pins)).

**QEMU `virt`** has no pin controller, no table and no pin driver.

**What a tree does and does not say.** In that same distribution's Pi 4
tree, UART0's default state names GPIO 32 and 33 only; GPIO 30 and 31
are in no enabled node's group. No enabled node names a header pin: the
header's buses are disabled nodes, enabled by overlays. So that tree
omits what erXos needs for Bluetooth and says nothing of the header. The
card ships a different tree, compiled from Linux 6.18's sources
(`tools/lib/erx/board_tree.rb`), whose UART0 groups no record read for
this design states: unverified.

### What the code does today

* **The header map** is built: the platform record's `pins`, the SoC
  pin table `hw/pins/bcm2711.txt`, and the reader with its refusals
  (`tools/lib/erx/header_map.rb`). `config.txt`'s `gpio=` lines come
  from it.
* **The root writes the on-board pins at boot.** The map's `onboard`
  rows become the manifest's `onboard_pins` rows. The system domain's
  root reads GPFSEL0 to GPFSEL5, plans new words in a pure C core that
  has fields for GPIO 28 to 57 alone (`kernel/core/bcm2711_pins.c`),
  writes the words that change, reads them back and prints one line
  (`liberx/backend/fiasco/bcm2711_pins.c`, `runtime_entry.c`
  `board_pins`). It writes function fields only, no pulls. Its mapping
  of the page stays writable for the system domain's life.
* **No driver holds the pin controller at run time.** `/dev/gpio` and
  its core are designed in
  [design-header-io.md](design-header-io.md#devgpio) and not built.
* **No Raspberry Pi 5 code exists.** Its record, `erx_rp1` and its pin
  writes are designs.
* `hw/dts/raspi4b-uart3.dtso`, erXos's overlay that enables the host
  link's UART, also names a pin group (`pinctrl-0`), which nothing
  reads; the same pins are rows 4 and 5 of the header map.

The root's write is the present implementation of "apply UART0's default
state". The pin driver takes that job over, and the root's core, shim,
report and manifest table are deleted with it
([Before and after](#before-and-after)).

## The construction

The board's pin table gives every pin one owner, and every owner's pins
a setting in each of its named states. One driver per pin controller
holds the controller's registers and makes them equal to the table: at
its start for every device that has one state, and afterwards only for
a state name or a GPIO request that the table and a grant allow. Each
write, and each answer to "is this pin set?", is a pure function of the
registers as read and the settings wanted.

Everything below follows from those three sentences.

**From source to register.** A pin fact takes one path:

1. The chip's documentation gives `hw/pins/<kind>.txt`, the board's
   wiring gives the record's `pins`, and the firmware's documentation
   and the board's readings give the firmware's settings table. The
   record reader checks the rows against both tables and refuses a
   table that breaks a rule.
2. The packer writes the table into the manifest, and the manifest check
   proves its clauses about units, holders, services and grants.
3. At boot the domain library writes each controller's rows into its
   holder's boot page as one `pins` record.
4. The pin driver reads the registers, plans, writes, reads again and
   plans again. What the second plan still holds is reported as not
   set.
5. At run time a request names a state or a GPIO pin; the driver checks
   it against the table and the holds, and plans, writes and checks as
   in step 4.

No step reads a pin fact from anywhere else, and no later step checks
an earlier one's output again.

### Invariants

| Invariant | Held by |
| --- | --- |
| **PC1.** A pin has at most one owner | one row per pin; the reader refuses a second |
| **PC2.** Once the kernel runs, only the pin driver writes a pin controller's registers | a controller's devices are one unit with one holder; only the kind's register module names the registers |
| **PC3.** erXos never writes the console's or JTAG's pins | their rows are pins the firmware's own settings set, which the reader checks; no such row is in the driver's record; a plan changes no field it has no pin for |
| **PC4.** A refused request writes nothing | `plan/2` returns every write or a refusal; a hold is decided before a plan is made |
| **PC5.** A client changes a pin only to a setting the table lists, for a pin in its scope | a request carries a state name or a GPIO `ctl` line, never a function or a register; the manifest check proves each grant's scope |
| **PC6.** A device is used only with its pins set | a pin driver's start is for a configuration and succeeds only when every device that configuration uses is set; it comes before the domain service, which creates that configuration's domains and no other, before the system release's own drivers of devices with rows, and in a unit before the unit's drivers; a driver that selects states touches its device only after a select has answered `ok` |
| **PC7.** A GPIO pin passes to a new holder only from its idle state, and who holds it is never read from the registers | a grant takes an unheld pin only when its registers read idle; the hold core's record alone says who holds a pin, and it releases at the holder's last close or its end |
| **PC8.** What `/proc` shows a pin to hold, and the state it shows a device to be in, are what the registers hold | read from the registers, never from the table and never from memory |
| **PC9.** A state does not depend on the states before it, and a reading is at most one state | every state of a device writes the same fields, since a state changes only what the row's plain setting states; the reader refuses two states of one device with the same settings |
| **PC10.** A start of the pin driver moves no line a driver chose | a start plans `default` for a device with `default` alone and nothing for a device with other states |

### The pin table

The platform record's `pins` lists the board's **pin controllers**. Each
entry has:

* its **name**, an identifier that is unique in the record (`gpio` on
  the Raspberry Pi 4), by which `/proc` and the log name the
  controller;
* its **kind**, the entry's `soc`, which names the SoC pin table it is
  checked against, `hw/pins/<kind>.txt` (`bcm2711`, later `rp1` and
  `bcm2712`). That file, written from the chip's documentation, lists
  each pin, the signals it can carry, and which peripheral block owns
  each signal;
* its **devices**, the entry's `controller`: the devices whose registers
  set its pins' functions, pulls and levels. On the BCM2711 that is one
  device. On the BCM2712 it is a pin controller and, once a row needs a
  level, the GPIO bank beside it; on RP1 the IO-bank and pad blocks;
* its **rows**, at most one per pin.

A row names a pin and its **owner**, which the record writes as the
row's `use`:

| Owner | Meaning | Who sets the pin |
| --- | --- | --- |
| a device of the record, by its path or, for a part of a PCIe function, its part's name | the pin carries that device's signal, or is a line that device's driver drives | the pin driver, from the row's settings |
| `gpio` | a plain GPIO pin, served to whoever is granted it | the pin driver, for the grant that holds it |
| the console's device, or `jtag` | a pin the firmware sets before the kernel runs | the firmware; never erXos |
| `reserved`, or no row at all | nothing touches the pin | nobody |

**The firmware's rows.** Calling a row the console's does not make its
pin the console's. The firmware puts the console where its own setting
says, whatever a table claims, and a table that named two other pins
would leave the real ones to be idled as plain GPIO. So a firmware row
is checked against the firmware, as every row is checked against the
chip. The board's **boot description**, the build code that writes the
firmware's configuration (`config.txt` on the Raspberry Pis,
`tools/lib/erx/boot_partition.rb`), keeps one **settings table**: each
setting it can write that makes the firmware set pins, with those pins
and the signal the firmware puts on each. On the Raspberry Pi 4:

| Setting | Pins | Written on | Evidence |
| --- | --- | --- | --- |
| `enable_uart` | GPIO 14 and 15, the mini UART's `TXD1` and `RXD1` | every card | seen on the board, whatever `gpio=` lines ask ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)) |
| `enable_jtag_gpio` | GPIO 22 to 27, JTAG's six signals | a development card | the Raspberry Pi documentation ([design-header-io.md](design-header-io.md#the-hardware)) |

A firmware row must be a pin of one of these settings, with that
setting's signal, and a setting's pins are all rows or none. The boot
description writes a setting when its pins are rows and the card is of
a kind the table lists for it. The rows themselves do not depend on the
kind of card: on a release card the six `jtag` rows stay rows, so the
pins are written by nobody and served to nobody, and `enable_jtag_gpio`
is not written, which the `config.txt` writer's test checks
([design-header-io.md](design-header-io.md#security)). The console's
rows come from one setting, written on every card, whose signals are
the console device's. So the pins the pin driver leaves alone are pins
the firmware is told to set, or pins nothing sets, and no other reading
of "the console's pins" exists in the build.

A device's row carries a **setting**: a `function`, which is one of the
pin's signal names from the SoC table, `in`, or `out` with a `level` of
0 or 1; and optionally a `pull`, `none`, `up` or `down`. A row that
names no pull never has its pull written, in any state: it stays as the
firmware left it, as under a device tree group that names no bias. Drive
strength and slew rate are not in the vocabulary, since no pin of a
driven device needs them; a property is added with the first row that
needs it.

**States.** A row may give further settings under state names:

```json
{"gpio": 32, "use": "eth", "function": "out", "level": 1,
 "states": {"reset": {"level": 0}}}
```

This is RP1's GPIO 32, the reset line of the Ethernet PHY, owned by
RP1's part `eth`: high in `default`, low in `reset`.

The plain setting is the device's `default` state. A device's states are
the names its rows use, and each state is whole: every pin of the
device, with the plain setting overlaid by what the state names. A state
names a pull only on a row whose plain setting names one, and a level
goes with `out` in every state. Every state of a device therefore writes
the same fields, so a state is a value, switching between two states
needs no history, and the order of switches does not matter. No two
states of a device, `default` among them, have the same settings, so a
reading of the device's pins is at most one of its states.

**The Raspberry Pi 4's table** is one entry of kind `bcm2711`, named
`gpio`: its header map's rows and its on-board rows, one row form in two
lists
([design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header)).
The on-board rows take pulls and states like any row.

### What the build refuses

The record reader checks the table and refuses, naming the row:

* a pin on two rows, a pin the kind's table does not list, an owner
  that is not a device or part of the record, or a controller name that
  is not an identifier or is used twice;
* a function the pin does not carry, or that is a signal of another
  device than the row's owner, so no row but the console's own carries
  a signal of the console;
* a firmware row that is not a pin of a setting in the board's settings
  table, or that names another signal than the setting's; a setting
  with some of its pins as rows and not all; console rows from two
  settings, from a setting whose signals are not the console device's,
  or from one that some kind of card does not write;
* a `level` without `out` or `out` without a `level`; a setting on a
  `gpio` or `reserved` row; a state on a firmware, `gpio` or `reserved`
  row;
* a state that names a pull on a row whose plain setting names none;
* two states of one device, `default` among them, with the same
  settings, since a reading could then be either;
* a device that in `default` lacks a signal its peripheral cannot work
  without, or that carries one signal on two pins in any state;
* a device whose states other than `default` name pins of two
  controller entries, since two processes would have to apply one
  selection;
* more than `pin_states_max`, 8, states for one device, or a state name
  that is not an identifier.

Rows the build imports from a tree join the record's before these
checks, so a tree cannot state what the record may not
([Rows from a board's tree](#rows-from-a-boards-tree)).

The manifest check adds, naming the unit or the row:

* **The devices of one controller entry lie in one unit.** A pin's
  function and its level are then written by one holder, whatever the
  chip's split into blocks.
* **A controller with a row for the pin driver has a holder.**
  Otherwise the table would be applied by nobody and a chip would be
  silent with no diagnostic.
* **Property 8's pin clause:** a unit whose registers can put a signal
  of the console's or the host link's device on a pin is held by no
  domain or by the system domain
  ([design-system.md](design-system.md#the-manifest);
  [Decisions](#decisions), 2). The clause reads the chip's pin table,
  so it holds whichever pins the rows use. The console's pins are rows
  checked against the firmware's settings, and the host link's are rows
  the pin driver itself sets.
* **A device with rows on a controller a configured domain holds is
  held by that domain**, so no start order between configured domains
  is ever needed ([Placement and boot order](#placement-and-boot-order)).
* **A device with other states that a domain holds can be selected by
  that domain.** The holder is the domain that holds the controller, or
  it has a `pins` grant that names the device. Otherwise the device
  would be driven with pins that no start and no driver ever set.
* **A domain serves plain GPIO from one controller.** `gpio` rows on
  two controllers that one domain holds are refused, so the pin numbers
  of a `gpio` grant are read against one controller: the one of its
  server's that has `gpio` rows. No board at hand needs two; one that
  does gives the service a parameter that names its controller.
* A `gpio` grant's `pins` outside the `gpio` rows of that controller;
  a `pins` grant's `devices` that have no state but `default` on a
  controller its server holds, that the grantee does not hold, or that
  another `pins` grant names.

### What is generated from it

1. **The manifest's `pins` table** (`abi/manifest.txt`): the rows of
   every controller, each state's setting spelled out, in pin order. It
   replaces `onboard_pins`.
2. **The pin driver's record.** For the holder of each controller the
   domain library writes one `pins` record
   ([design-fiasco.md](design-fiasco.md#device-records)): the
   controller's name and device indices, the state names its rows use,
   and its rows in a packed layout that `abi/erx_abi.txt` declares, each
   a pin, its owner (a device row's index, or the mark for `gpio`), a
   state, a function number of the kind, a pull and a level. The
   firmware's rows and `reserved` rows are left out. The record is the
   driver's whole table, so it has no setting for a pin it must not
   write. For each device with `default` alone it also carries which
   configurations use the device, which the generator derives from the
   manifest's holders, `line` grants and rescue marks
   ([At start](#at-start)). It is a word of the holder's boot page, which
   `boot_strings_max` bounds. A table that does not fit must fail the
   build and not the boot: the manifest check's planner, which checks
   each configured domain's page for room
   ([design-system.md](design-system.md#the-manifest), property 12),
   counts the record there and in the system domain's own page.
3. **Each kind's function numbers.** A generator turns
   `hw/pins/<kind>.txt` into the map between a pin's signal names and
   the kind's function numbers (on the BCM2711 the alternate number, 0
   to 5). The packer writes the manifest's rows through it and `/proc`
   shows a function's name through it; the kind's module turns a number
   into its register code through the generated register names. No code
   is written by hand in a driver or a record.
4. **The firmware's settings.** The boot description writes each setting
   of its table whose pins are rows, on the kinds of card the table
   lists for it: on the Raspberry Pi 4 `enable_uart` on every card, and
   `enable_jtag_gpio` on a development card alone.
5. **Which bus devices are driven**, and **who may hold the
   controller**, as the header map already derives them
   ([design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header)).

## The pin driver

`erx_pins` is one application. It runs one process for each controller
its domain has a `pins` record of, over three modules in the shape of
every erXos driver ([style](style.md#functional-core)):

| Module | Decides or does |
| --- | --- |
| `erx_pins_core`, pure | from the table and a request, the settings wanted: a device's state, a GPIO pin's `ctl` line, a pin's idle setting; from the table and a reading, the state a device is in; who holds which GPIO pin, through `erx_hold` ([design-header-io.md](design-header-io.md#holding-and-granting)) |
| `erx_pins_<kind>`, pure | **the plan**: from the registers as read and the settings wanted, the register writes; from a level register, the pins' levels; from an event register, the pins that fired and the command that acknowledges them |
| the kind's register module | reads and writes the registers by generated name, through the device NIF |

It takes the place of the `erx_gpio` application and `erx_gpio_core` of
the header design; `/dev/gpio` is its tree.

**The chokepoint.** Only a kind's register module calls the generated
accessors of that kind's peripherals, which the device chokepoint rules
check as they keep every device's registers to its shim; a second
module that names one fails the build. A pin controller's registers
are in no other peripheral's table, so no other driver's record reaches
them by a wrong name
([design-shared-devices.md](design-shared-devices.md#pages-inside-a-domain)).

### The plan

```
erx_pins_KIND:plan(Read, Wanted) -> {ok, Steps} | {error, {Pin, Reason}}
```

`Read` is the value of each readable register the wanted pins have a
field in. `Wanted` is a list of pins with their settings, a function
being a number of the kind, `in` or `out`. `Steps` is a list of writes,
each naming the pins it is for, of two forms, because a pin controller
has two kinds of register:

* A **field write**, `{field, Pins, Register, Mask, Bits}`, goes to a
  configuration register, which holds a field for each pin and reads
  back what was written: the BCM2711's function, pull and detect-enable
  registers, a pin's `CTRL` and pad registers on RP1. The register
  module writes the reading with the masked bits replaced by `Bits`.
* A **level command**, `{command, Pins, Register, Bits}`, goes to a
  register in which a written one acts on its pin and a written zero
  does nothing: the BCM2711's GPSET and GPCLR, which load a pin's output
  latch. `Bits` has ones for wanted pins only. No reading goes into a
  command, and a command register is never read to learn a setting.

The function is total and writes nothing itself:

* **Refused whole.** A pin the kind does not have, a function number
  outside the kind's range, `out` without a level or a setting key the
  kind does not know refuses the plan, and nothing is written.
* **Only what differs.** A field write that would change no bit is left
  out. A level command is left out only when the pin already reads as
  an output at that level. Otherwise it is planned: the level register
  shows the wire and not the latch, so an input that reads high says
  nothing about what the pin will drive. A plan over pins already set
  is empty, so a restarted driver glitches no line.
* **Only the wanted pins.** A field write's mask covers the wanted pins'
  fields and no other, and a command names no other pin. The console's
  pins have no row in the driver's record, so no plan can name them,
  and this rule keeps their fields when a neighbour in the same
  register changes.
* **An order that drives nothing unasked,** which each kind states for
  its own registers. On the BCM2711: pulls first, then level commands,
  then functions, so a pin's latch is loaded while the pin is still an
  input and it starts to drive at the level asked. On RP1 a pin's pad
  may be written twice ([design-rp1.md](design-rp1.md#pins)).
* **Total over any reading.** A reading is what a device returned, and
  RP1 is a device on a bus. Every field is taken under its mask, a code
  the kind has no name for is carried as a number, and no reading makes
  a plan write a pin that is not wanted or a value the table does not
  hold.

**Applying and checking.** The register module writes the steps in
order and reads the configuration and level registers again, and the
driver calls `plan/2` again with the same `Wanted`. The check covers
what persists and can be read: a pin's function and pull as its
configuration registers hold them and, for a pin that is now an output,
its level as the level register shows it. That last reading is how a
level command's completion is seen, since the command register itself
tells nothing. A pin the second plan names in no step is `set`; a pin
it names in a step **differs**. The check is the planner itself, so no
second comparison can disagree with it, and on a kind whose pins have
several registers a pin is `set` only when all of them agree. Nothing
is rolled back: the steps already written stay, since the values before
them are no safer, and the pins that differ are named in the answer and
the log.

**Events are not part of a plan.** An edge event is consumed, not set.
A second function of the kind takes the event register's reading and
returns the driver's own pins that fired, with one command that carries
exactly those bits and so clears them and no event of a pin without a
row. Nothing checks that command by reading again: a bit found set
afterwards is a new event, taken at the next reading, and an
acknowledge that did not take shows as one edge reported twice, never
as an edge lost.

Kinds differ only here. The `bcm2711` kind plans the function field of
GPFSEL (3 bits a pin, register `pin div 10`), the pull field of
GPIO_PUP_PDN_CNTRL (2 bits a pin, register `pin div 16`) and the pin's
bit in each of the six detect enables (register `pin div 32`) as field
writes, and GPSET or GPCLR as level commands. The six are GPREN and
GPFEN for a rising and a falling edge, GPHEN and GPLEN for a high and
a low level, and GPAREN and GPAFEN for an asynchronous rising and
falling edge. A pin's edge setting gives all six bits, and a setting
without one leaves them as read: `rising` sets
GPREN's, `falling` GPFEN's, `both` the two, and every other bit is
clear, so a pin detects the edges its setting names and nothing else.
The `rp1` kind plans each pin's `CTRL` and its pad together, all field
writes ([design-rp1.md](design-rp1.md#pins)). The `bcm2712` kind waits
for a facts record of its registers.

### At start

The driver reads the registers of every pin in its record, makes one
plan, applies it, checks it and reports. The plan holds:

* the `default` state for every device that has `default` alone on this
  controller;
* nothing for a device with other states here;
* for each `gpio` pin its **idle state**: input, no pull, and every
  detect enable clear, so it detects no edge and no level; the setting
  that drives nothing
  ([design-header-io.md](design-header-io.md#devgpio)).

The plan is the same at the first start of a boot and at a restart
after a failure, and it is safe at both for one reason: a start writes
a device's pins only where no driver ever selects.

* A device with `default` alone has one setting its driver can rely on,
  so putting it there is what the driver expects at any moment. After a
  restart the plan for it is empty unless something outside erXos moved
  its pins.
* A device with other states is its driver's, which selects the state
  it needs as it starts ([States at run time](#states-at-run-time)).
  The pin driver's start never writes it: not at boot, when its driver
  has not started, and not after a failure, when its driver may be in
  the middle of a transfer at the supply and signalling voltage it
  selected, or in the middle of a selection the failure cut short. It
  stays as it is until its driver selects, and with no driver it stays
  as the firmware left it.

So the pin driver needs no way to tell its first start from a later
one, and no start moves a line a driver chose.

The driver reports one log line: how many pins it wrote, how many
already agreed, each device with other states and the state it reads
as, and each pin that differs, with the setting wanted and the setting
read.

**A device left unset is not used.** The table is erXos's own data,
checked at build against the chip's table and the firmware's settings,
and the registers have one writer. A pin that still differs after the
start's plan is therefore a fault of the board, of the table or of the
kind's module. A device left without its pins must not be used: nothing
says its driver would notice, since an SPI controller clocks bytes in
whether or not its pins reach the header and would return them as data.
Nothing in a running boot keeps a holder from a device it was given, so
what would use the device must not start. Two things that already start
as a whole give that, and no new one is added: a unit, and each of the
system release's two configurations, normal and rescue
([design-system.md](design-system.md#boot)).

**Who a device is for** is a fact of the manifest. For a device with
`default` alone it is:

* the configured domain that holds the device;
* for a device the system domain holds, the domain that a grant of the
  `line` service names it for, as the Raspberry Pi 4's UART0 is the
  Bluetooth domain's
  ([design-bluetooth.md](design-bluetooth.md#the-controllers-line)), or
  the system release itself where no grant names it, as the host link's
  UART;
* no one, where no domain holds the device.

A configuration **uses** a device that is for the system release or for
a domain the configuration starts. The rescue configuration starts the
domains the manifest marks for rescue and the normal one starts them
all, so what rescue uses the normal configuration uses too. The
generator writes into the pin driver's record which configurations use
each device
([What is generated from it](#what-is-generated-from-it)).

**A start is for a configuration, and it fails when it leaves unset a
device that configuration uses.** A device for no one that is left
unset, and a `gpio` pin that does not read idle, are in the log line
and cost nothing more: no one uses the first, and the second is refused
when a grant would take it ([Plain GPIO](#plain-gpio)).

* **In the system domain the release boots the larger configuration
  whose devices are set.** It starts its pin drivers for the normal
  configuration. When that fails and every device named is one the
  normal configuration alone uses, it starts them for rescue instead
  and boots its rescue configuration, as it does when the reset count
  is past three ([design-system.md](design-system.md#boot)). No domain
  that a device left unset is for is created, so nothing reads or
  writes through the device: a line of the line service that has no
  domain moves bytes for no one. The console's login says that the
  machine booted for rescue and names the controller and the pins. This
  happens within the one boot, with no reset, and again at every boot
  until the pin takes its setting.
* **When a device that rescue uses is left unset, no configuration
  remains.** The system release does not boot, and the machine ends by
  `erx.panic` with the log line and the crash record
  ([design-platforms.md](design-platforms.md#failure-handling-diagnostics-and-debuggability)).
  That end comes before the slot writer advances the reset count, so it
  is not counted and rescue does not follow it: the machine ends the
  same way at every boot until the board is repaired or its card is
  written with a table that fits the board. Rescue could do no better,
  since it uses the device, and a `required` domain that cannot start
  before the slot writer runs ends the machine the same way. A start
  plan that the kind's module refuses, which writes nothing, also
  leaves no configuration.
* **In a unit** there is one configuration, the unit's start, and every
  device with rows there is a part of the unit and so its holder's. A
  start that leaves one unset fails. The unit's supervisor starts none
  of the drivers that come after the pin driver, and the unit fails as
  it does when its function's own driver cannot start: on RP1 the
  domain ends and the board runs without RP1
  ([design-rp1.md](design-rp1.md#mastering)).

A restart of a pin driver is a start for the same configuration as the
start it replaces, under the same rule. In the system domain the pin
driver is a `permanent` child, and a restart that keeps failing must
end the machine, since the devices it could not set are in use: its
supervisor gives up and ends the system release's application, which
ends the runtime and the machine as the domain service's end does
([design-system.md](design-system.md#system-services)). The boot that
follows meets the pin at its start. A boot that turns to rescue for its
reset count keeps the pin drivers it started, for the normal
configuration.

So a device with `default` alone has its pins set whenever anything
that uses it runs, and that is all the readiness there is: the driver
keeps no mark of it for a device, nothing asks for one, and neither the
giving of devices to domains nor the starting of their drivers changes.
One fact passes from the pin drivers' start to the rest of the boot:
which of the release's two configurations boots.

A device with other states is refused where its use begins, by its own
driver: a driver that selects states touches its device only after a
select has answered `ok`
([States at run time](#states-at-run-time)).

### States at run time

```
erx_pins:select(Device, State) -> ok | {error, enoent | eio}
```

`Device` is a device's manifest row index, the word its own record
carries. The call goes to the process of the one controller that has
the device's states. That process plans the state's settings for the
device's pins, applies and checks. `enoent` is a state the table does
not give the device. `eio` is a pin that differs after the write.

* **Who may select.** A process of the pin driver's own domain, for any
  device of the table; another domain only through a `pins` grant whose
  scope names the device ([Interfaces](#interfaces)).
* **What a driver that selects owes.** It selects the state it needs as
  it starts, before it touches its device, as the Ethernet driver's
  start resets its PHY. After any answer but `ok`, and after a select
  that the pin driver's end cut short, the device may be in no state:
  the driver fails its start, or stops using the device, until a select
  answers `ok`. This is the whole recovery contract between a driver
  and the pin driver, in one domain or across two, and it needs no
  message from the pin driver: the failed answer is the notice.
* **Across domains the first select waits for the grant.** A `pins`
  grant, like every grant of a service the system domain serves,
  reaches its domain in the answer to the domain's ready report, after
  the domain's release has booted
  ([design-system.md](design-system.md#facets-a-configured-domain-serves)).
  So a driver that selects through a grant does not start its hardware
  as its application starts. That part is started by the row's `-eval`
  once init holds the ready answer's facets, as the Bluetooth domain
  starts its stack and the PCIe domain its enumerator
  ([design-bluetooth.md](design-bluetooth.md#the-bluetooth-domain)).
  Until its first select answers `ok` the driver has not touched its
  device and serves no request for it. A grant that does not come,
  because the service names no living process, is logged by the domain
  service as any service left out is, and the device stays unserved
  until the domain restarts.
* **A state stays until another is selected.** Nothing returns a device
  to `default` on its own: not the end of the process that selected it,
  and not a restart of the pin driver. A restarted driver corrects
  whatever its predecessor left, by the select its start begins with. A
  driver that is stopped leaves its device in the state it last
  selected.
* **The pin driver remembers no selection.** The state a device is in is
  read from the registers whenever it is asked for, by `status` and by
  `/proc`: the one state whose plan over the reading is empty, or
  `unset` when there is none. Two processes that select for one device
  are served in the order their requests arrive and the later stands.
  Nothing is released when a selector ends, so no cleanup can undo a
  later selection.
* **A line a driver drives is a state, not a GPIO request.** RP1's
  Ethernet driver resets its PHY by selecting `reset`, waiting 5 ms and
  selecting `default`. A card's signalling voltage or a radio's power
  enable is the same. The driver's code names a state, and the board's
  table says which pin and which level.
* **A state that moves a function** (pins that change for low power, a
  bus whose signals move between two pin pairs) is designed with its
  first consumer. The check for required signals binds `default` alone,
  so the table can hold such a state, and no erXos driver selects one.

### Plain GPIO

A `gpio` pin is served through `/dev/gpio` exactly as
[design-header-io.md](design-header-io.md#devgpio) describes: one
directory per pin of the grant's scope, `ctl`, `value` and `event`, one
holder at a time, and the pin back in its idle state when its hold
ends. The `ctl` vocabulary is `in`, `out 0`, `out 1`, three pulls and
four edges, so a GPIO client cannot ask for an alternate function.

A pin passes to a new holder only from its idle state. When a grant
takes a pin that nobody holds, the driver plans the idle state for it,
applies and checks, and when the pin differs it answers `eio` and
grants nothing. A further open by the pin's holder plans nothing, so
opening `value` after `ctl` leaves what the holder set. A pin whose
return to idle did not take is thus never handed, still driven, to the
next holder, and the driver keeps no mark of it: the next taking reads
the registers again.

Who holds a pin is the hold core's record and nothing else. It is never
read out of the registers, where a holder's `out 1` and a device's
level look the same.

### A pin that is sometimes a device's

Some connector pins could serve two uses on one machine: GPIO 18 is
plain GPIO until a fan needs PWM on it. This design does not give that.
A pin has one row, so on one image GPIO 18 is plain GPIO or PWM0's, and
the other choice is another record.

Serving one pin both ways at run time is designed with its first
consumer, PWM ([design-header-io.md](design-header-io.md#pwm)). One
thing is fixed for that design here: who has such a pin is a hold in
`erx_hold`, taken and released by the hold's own events, an open, the
last close and the holder's end. It is never inferred from what the
registers hold, and what a restart of the pin driver, which loses the
hold core's record, does to such a pin is that design's to state.

## Where each fact comes from

| Fact | Source | Why there |
| --- | --- | --- |
| which signals a pin can carry, and their codes | `hw/pins/<kind>.txt`, from the chip's documentation | a fact of the chip, the same on every board |
| which pins the firmware sets, and to what | the boot description's settings table, beside the code that writes each setting | a fact of the firmware, true only of a setting the build writes |
| a pin's owner | the board's pin table | authority: the build proves who can reach the console's wires |
| a pin's setting in each state | the same row | wiring, the same at every boot |
| which states exist | the same rows | so the conflict check sees every state of every device at once |
| who may select a device's state or hold a GPIO pin | the manifest's facet rows | grants are the manifest's |
| what the pins hold right now, and the state a device is in | the registers, read by the pin driver | never the table's claim, and never the driver's memory |

**States live in the table, not in each device's record.** A device's
record carries nothing about pins. The check that no two devices claim a
pin needs every state in one place, the pin driver needs them and the
device's driver needs only names, which its own code has.

### Rows from a board's tree

A board with dozens of wired pins states them in its device tree, as
groups that each device's `pinctrl-N` properties name. Writing them
again by hand would copy a fact the build already has. For such a board
the build reads them:

* The record's controller entry lists the devices whose rows come from
  the tree. The list is an allow-list: a device not on it takes nothing
  from the tree, and the console's device is never on it.
* For each, the host build of `erx_dt`, the one tree reader
  ([design-device-tree.md](design-device-tree.md#the-reader)), answers
  the device's states: `pinctrl-names` gives the names, a node with
  `pinctrl-0` and no names has `default` alone, and each `pinctrl-N`
  gives the group nodes, which must lie under the controller entry's
  own node.
* A pure decoder for the controller's kind turns each group into rows.
  Two forms exist on the supported boards: pin numbers with a function
  code and pull codes (`brcm,pins`, `brcm,function`, `brcm,pull`), and
  pin and function names with `bias-` properties. A name or code is
  matched exactly against the kind's table.
* The rows join the record's own before any check, so every rule above
  binds them. A pin that the record and the tree both state is a pin on
  two rows and is refused: there is no agreement check, since no fact
  has two writers. A group that names a firmware pin is refused the
  same way, one that gives any pin a signal of the console is a signal
  of another device than its owner, and a state that adds a pull to a
  pin whose default group has none is refused as in the record.

The reader and the decoders refuse a property whose length is not a
whole number of cells, a group outside the controller's node, a pull or
function list that is neither one value nor one per pin, a pin or
function the kind's table lacks, a group property the decoder does not
know, and more groups or pins than their bounds. The tree read is the
one the build compiles and ships; a board whose tree the build does not
compile lists no device.

**Never at boot.** The root reads the live tree for facts only the
firmware knows ([design-device-tree.md](design-device-tree.md)). A pin's
owner is not one: it is the same at every boot, and it is authority,
since a tree that moved the console's pins to another UART would hand
the console's wires to that UART's holder. A boot-time read would need
a build-proved bound on what the tree may say for each device, and that
bound is this table. So nothing at boot reads a `pinctrl` property, and
an overlay the firmware merges changes no pin.

The Raspberry Pi boards' rows are written by hand: their wired pins
number about ten on the Pi 4 and about twenty-five on the Pi 5. The
importer is built for the first board that needs it
([Decisions](#decisions), 4).

### What the firmware leaves

The driver assumes nothing about a setting a row states. Its plans are
functions of the registers as read, so a pin the firmware already set
costs no write and a pin it left wrong is corrected. Four things remain
the firmware's:

* **The console's pins and JTAG's** are set before the kernel runs, by
  the settings the boot description writes, and are never written by
  erXos. A board whose firmware does not set its console's pins has no
  early console, and that is its kernel platform layer's to solve.
* **A pin with no row** is never written, and its field is carried
  through every write of the register it shares.
* **What no row states.** A pull a row leaves out, drive strength, slew
  rate and input hysteresis, and on RP1 each bank's pad voltage stay as
  found. A device that needs one of them gets it stated in its row, the
  vocabulary growing by that property, and `/proc` shows each as read
  until then.
* **The registers after hand-over.** A field write is sound only while
  nothing else writes the controller. The design requires that of the
  firmware, as
  [design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header)
  already does; the board probe's readings a minute apart are evidence,
  not proof.

On RP1 a function alone connects nothing, since each pad has an
output-disable bit that is set at reset and an input-enable bit that is
clear at reset; the `rp1` kind plans both with every function, and a
pin there is `set` only when its pad agrees too. One field of a pin's
`CTRL` stays the firmware's there: `INOVER`, by its name an override of
the input the peripheral sees, whose values the facts record does not
give. Until it does, the kind neither writes nor checks the field, so
an input signal on RP1 rests on the firmware having left it alone, and
`set` does not vouch for it ([design-rp1.md](design-rp1.md#pins)).

The boot description writes no `gpio=` line: the driver's plan puts the
header's bus pins and the host link's as the table says
([Decisions](#decisions), 3).

### A machine's own choices

* **An app adds no pin.** It reaches pins through services: `gpio` with
  a `pins` scope, `i2c1`, `spi0`. Its declaration names services the
  board's `apps` row offers
  ([design-packaging.md](design-packaging.md#the-declaration)), and
  admission checks them. The table already gives those pins to those
  services, so installing an app changes no row.
* **A user who wants a connector pin for something else,** or a
  different default (the header's I2C on other pins), needs a different
  record, and so a different image. Choosing at run time among uses the
  build checked is not designed here
  ([above](#a-pin-that-is-sometimes-a-devices)).
* **Not a device tree overlay.** The firmware would merge it into the
  tree, which is never read for pins; its files come from the
  firmware's distribution under the GPL; and `config.txt` is a file the
  build writes.

## Placement and boot order

**One holder writes a controller.** The kernel gives registers by whole
pages ([design-system.md](design-system.md#devices)), so whoever holds a
pin controller can write every pin in it. Its unit therefore has one
holder, and the pin driver runs there.

**The system domain holds a pin controller that can put the console's
or the host link's signals on a pin**, and property 8 allows no other
holder ([Decisions](#decisions), 2). On the Raspberry Pi 4 that is the
`gpio` unit. The BCM2712's two controllers go to the system
domain as well, whether or not they set the console's pins, which no
source read here says: the SD slot's pins must be set before the storage
domain starts.

**The system release starts `erx_pins` before the domain service and
before its own drivers of devices with rows**, the line service and the
host link. The start of `erx_pins` returns when its start plan has been
applied and checked, and with it the release settles which of its two
configurations it boots ([At start](#at-start)). The domain service
creates that configuration's domains as it starts, and the system
design already requires every service whose facets the manifest grants
them to be started before it, by an
application the release starts earlier
([design-system.md](design-system.md#facets-a-configured-domain-serves)). `gpio` and
`pins` are such services where a board grants them, but the order is
this design's requirement on every board with a controller the system
domain holds, since defaults need it whether or not anything is
granted. Three things follow:

* No configured domain exists unless the pin drivers started for a
  configuration that creates it, and so with every device it is for
  set ([At start](#at-start)). So a bus's pins, the SD controller's and
  the vault's TPM's read as `default` before any domain that drives
  them is created. No bus driver depends on any domain but the system
  domain, on which every domain already depends.
* UART0's pins are set before the line service opens the line to the
  Bluetooth controller.
* Nothing must be set "before any domain runs" except what the firmware
  sets: the console's pins.

**A controller inside another domain's unit is driven there.** RP1's pin
blocks are parts of RP1's function, so the `rp1` domain runs their
`erx_pins` under its unit supervisor. That supervisor is `rest_for_one`
and starts `erx_rp1`, then `erx_pins`, then the supervisor of the parts'
drivers ([design-rp1.md](design-rp1.md#mastering)). The pin blocks are
parts whose driver resets nothing and masters nothing, so RP1's
mastering barrier counts the other parts alone. A failed start of
`erx_pins` fails the unit's start, as a failed start of `erx_rp1` does.
Every device with rows there is a part of the same unit, which the
manifest check holds to.

**Several controllers in one domain** are one process each, started and
planned independently. A device may have `default` rows on more than one
of them, as the Raspberry Pi 5's SD slot has pad pulls on the main
controller and its card detect on the always-on one: each controller's
process sets its own rows at its start, and nothing ties the two
together. A device's other states lie in one controller, which the
reader checks, so a select is one process's one plan, and the device
alone says which process: `erx_pins:select/2` and the `pins` tree find
the controller from the device. Plain GPIO is served from one
controller of a domain, which the manifest check holds to.

**Pin controller and GPIO controller.** On the BCM2711 they are one
device. Where they are two, the controller entry names both, the
manifest check keeps them in one unit, and one process plans both. No
GPIO driver asks a pin driver to prepare a pin, because they are the
same process. A GPIO bank that no row needs is in no entry and no unit,
and it joins its pin controller's entry with the first row that needs a
level.

## Interfaces

**Inside the pin driver's domain:** `erx_pins:select/2` above.

**Across domains,** two interfaces that `abi/services` declares, each a
files tree served through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)):

| Service | Interface | Scope parameter | Mount point | Tree |
| --- | --- | --- | --- | --- |
| `gpio` | `gpio` | `pins`, a set of pin numbers | `/dev/gpio` | one directory per pin: `ctl`, `value`, `event` ([design-header-io.md](design-header-io.md#devgpio)) |
| `pins` | `pins` | `devices`, a set of device rows | `/dev/pins` | one directory per device, named by its row index: `ctl` and `status` |

Neither request can be read against the wrong controller. A pin number
of the `gpio` service is a pin of its server's one controller with
`gpio` rows. A device of the `pins` service names its own controller,
the one its states lie in.

`/dev/pins/N/ctl` takes one line, `state NAME`, with the answers of
`select/2`; any other line is `einval`. An open of `ctl` holds nothing
and its close changes nothing, since a state stays until another is
selected. `/dev/pins/N/status` reads on its first line the state the
device reads as, or `unset`, and then one line per pin: the pin, its
function, pull and level as read. The `pins` service is built with the
first driver that selects a state from another domain.

**Inspection.** Each pin driver reports to its domain's inspector at
`[domains, D, pins, Controller, Pin]`, `Controller` being the entry's
name, a path `abi/inspection.txt` declares, shown under
`/proc/domains/D/pins/`
([design-live.md](design-live.md#the-proc-tree)): the pin's owner (a
device row index or `gpio`), the state its device reads as or `unset`,
the pin's `default` setting from the table, the function, pull and
level its registers hold, and for a GPIO pin its holder, edge setting
and edge count. Nothing shown is a request the driver remembers.
A function code the kind's table has no name for is shown as its number.
A value the driver cannot read is `unknown`, never the table's.

## Concurrency and failure

One process per controller serves one request at a time, so each field
write is one read-modify-write by the only writer of those registers. A
hold's check and its effect are one step of that process
([design-header-io.md](design-header-io.md#holding-and-granting)).

A request fails in one of two ways, and they are kept apart. It is
**refused** before any write, by the table, the hold or the planner, and
then nothing is written. Or its steps are written and a pin **differs**
at the check; then the steps stay written and the request answers
`eio`. The pin driver remembers neither: what `status` and `/proc` show
afterwards is what the registers then hold.

| Event | Result |
| --- | --- |
| a request is refused: a state the table lacks, a pin another holds, a plan the kind refuses | nothing is written; the request answers its error |
| a pin differs after a select | `eio`, and the pin is named in the log; the device then reads as whatever its registers hold, its old state, the new one or `unset`; its driver does not use the device until a select answers `ok` ([States at run time](#states-at-run-time)) |
| a device with `default` alone is left unset by a start plan: a field that did not take its write, or an output whose wire is held at the other level | the start logs the controller and each pin, and fails when its configuration uses the device ([At start](#at-start)). In the system domain at boot, a device that the normal configuration alone uses makes the boot a rescue boot, and a device that rescue uses stops it: the machine ends by `erx.panic` at every boot, uncounted by the reset count, until the board or its card is repaired. At a restart that keeps failing the machine ends, and the next boot meets the pin at its start. In a unit the unit fails. A device for no one costs the log line alone |
| a GPIO pin differs after a `ctl` or `value` write | `eio`; the hold stands |
| a GPIO pin does not read idle when its hold ends, or after a start plan | the hold ends, or the start goes on with the pin in its log line; the next grant to take the pin plans idle again and gets it only if it then reads idle |
| a register reads a value no row gives: a code with no name, or all ones from a device that has left its bus | the plan is total over it; the pins differ; no pin without a row is written |
| a device's driver ends | its device stays in the state it selected, and the restarted driver selects again; a GPIO pin it held goes idle, by the hold's release |
| the pin driver's process ends | a select in flight fails, by `eio` from the `pins` tree or the caller's failed call, and its driver holds to its contract. The supervisor restarts the pin driver, which plans as at any start: nothing for a device with other states, even one the end caught between two; `default` for a device with `default` alone, which writes nothing unless its pins were moved; GPIO pins to idle, and old GPIO handles answer `eio`. Under a unit's `rest_for_one` supervisor the unit's drivers are stopped before it restarts and started after |
| the domain of a controller ends (`rp1`) | the registers keep their values; the restarted domain's driver plans from what it reads |
| the firmware writes the controller after hand-over | a race the design excludes by requirement, not by mechanism |

## Refusals and error results

| Request | Answer |
| --- | --- |
| `select` of a state the table does not give the device | `enoent` |
| an open of a GPIO pin another grant holds | `ebusy` |
| a `select`, the taking of a GPIO pin or a GPIO write after which a pin differs; a request in flight when the pin driver ends; a GPIO handle of an ended driver | `eio` |
| a `ctl` line outside its grammar | `einval` |
| a walk to a device or pin outside the grant's scope | `enoent` |

The build's refusals are listed under
[What the build refuses](#what-the-build-refuses) and
[Rows from a board's tree](#rows-from-a-boards-tree).

## Security

* **The holder of a pin controller is in the console's trusted base**
  wherever property 8's clause applies, since it can take or read the
  console's line whatever its driver's checks say
  ([design-header-io.md](design-header-io.md#the-pin-controller-and-the-console)).
  This design changes who writes, not who can.
* **The trees' code runs with the root task's authority** where the
  system domain holds the controller: the code that reads a GPIO or
  `pins` client's request is in the trusted base, and a fault in it
  resets the machine ([Decisions](#decisions), 2). What it reads from
  a client is a `ctl` line and a walk name, each through a parser with
  a fuzz target.
* **Leaving the console's rows out of the driver's record guards
  against a wrong table, not against the holder.** It keeps a correct
  driver from idling the console's pins. Code that runs in the holder's
  domain can write any pin, with or without a row.
* **A client can ask only for what the table lists.** A request carries
  a state name or a line of the GPIO `ctl` grammar. None carries a
  function code, a register or a pin outside the asker's scope.
* **Untrusted input** reaches three parsers: the `ctl` grammars and walk
  names of both trees; the platform record's `pins`; and, for a board
  that uses it, the tree importer's groups. Each has a fuzz target. The
  live tree's pin properties reach no parser.
* **A register reading is a device's word.** The planner is total over
  every reading and writes only wanted pins whatever it reads
  ([The plan](#the-plan)), and what `/proc` shows of a reading is a
  number or a name from the kind's table.
* **Text.** State names, controller names and signal names are
  identifiers the build checked, and every other value is a number, so
  the trees and `/proc` show nothing a device or a client wrote.
* **Driving a wire** against another driver of it can damage a board.
  That is the wiring's and the operator's, as on any system that offers
  GPIO. Holding an output's wire at the other level while the machine
  boots costs it its normal configuration, or its boot
  ([At start](#at-start)); that too takes a hand on the board's pins.
* **On Fiasco** nothing differs: the driver is a driver of its domain
  like any other. The root's lifelong writable mapping of the GPIO page
  goes away with the root's write.

## Verification

**Host tests of the pure cores**, each paired with a seeded fault that
must make it fail.

| Test | Seeded fault |
| --- | --- |
| `erx_pins_bcm2711:plan/2` against the board's reading of GPFSEL3, `0x00000fc0`, wanting UART0's four pins | each field one pin off; a whole-register write, which zeroes GPIO 34 to 39; ALT4 and ALT5 swapped |
| a refused plan returns no step | the steps before the refused pin returned |
| checking by planning again, over a register model: empty after the steps are applied; names the one pin whose field write was dropped, in a register two wanted pins share; names an output pin whose level reads otherwise | the second plan replaced by `ok`; a step that does not carry its pins |
| the plan is idempotent: planning over its own result is empty | the "only what differs" rule removed |
| a level is a command: `out` with level 1, for a pin that reads high as an input, plans GPSET with that pin's bit alone | the command left out because the level register reads 1; a GPSET word that carries other bits of a reading |
| an event acknowledge names only the driver's own pins that fired, and a bit set again after it is reported as a new event | the event word written back as read, which clears GPIO 15's event; the acknowledge checked by a second plan, which reports a new edge as a failure |
| a neighbour's field is kept: a plan for GPIO 12 and 13 leaves GPIO 14 and 15 as read | a GPFSEL write that is not a read-modify-write |
| pulls: GPIO 34 to 39 as the Wi-Fi rows state them; a row with no pull plans no pull write in any state | up and down swapped; a row without a pull writing `none` |
| write order: pull, level, function | the function written before the level, which a model that samples the pin between writes exposes |
| total over readings, a property test: for any register words the steps touch only the wanted pins' fields and bits | a field taken without its mask |
| `erx_pins_rp1:plan/2` over a pad at its reset value, output disable set and input enable clear, plans both bits with the function | a plan that writes `CTRL` alone |
| `erx_pins_rp1:plan/2` order, over a model that samples the pad between writes: from a pad that can drive and a `CTRL` that forces level 1, a plan to a signal sets output disable, writes `CTRL`, then clears it; a change of level alone is one `CTRL` write | `CTRL` written while the pad can drive; a level change that sets output disable first |
| `erx_pins_core` states: `default` overlaid by a state; an unknown state | the overlay dropping a pin the state does not name |
| the start plan: `default` for a device with `default` alone, nothing for a device with other states whatever it reads as, GPIO pins idle, no firmware pin named | `default` planned for a device with other states, which is what a restart under a card at 1.8 V would write; a firmware row written into the record |
| a start fails for a configuration that uses a device it leaves unset, over a register model that drops one field write: in a device the normal configuration alone uses, the start for the normal configuration returns an error that names the controller, the device and the pin, with the setting wanted and the setting read, and the start for rescue answers `ok`; in a device rescue uses, both fail; in a device for no one, and for a `gpio` pin, both answer `ok` and the report names the pin | the normal start answering `ok` with the pin only logged, which boots SPI0's driver with its pins as inputs; the rescue start failing on a device rescue does not use, which is the reset loop |
| the release's choice of configuration, a pure function of the starts' results: normal when every start answers `ok`; rescue when the failed starts name only devices the normal configuration alone uses; none when one names a device rescue uses, or a refused plan | rescue chosen when a device rescue uses is named |
| which configurations use a device, in the generated record: a configured domain's device by that domain's rescue mark; UART0 by the rescue mark of the domain its `line` grant serves; the host link's UART, which no grant names, as the system release's; a device no domain holds as no one's | `line` grants not read, which makes UART0 the system release's, so that its pins stop every boot; every domain read as marked for rescue |
| a hold starts from idle: taking a pin that still differs after its idle plan answers `eio` and holds nothing; a second open by the holder plans nothing | the check removed, which hands a driven pin to the next grant; idle planned at every open, which turns the holder's `out 1` back to an input when it opens `value` |
| the table reader, one table that breaks only each refusal, among them: the console's rows on GPIO 32 and 33 with GPIO 14 and 15 as `gpio`; a `gpio` row on GPIO 14; `enable_jtag_gpio`'s pins with five rows; a state that names a pull its plain setting lacks; two states of one device with the same settings; a device with states on two controllers | as each refusal says |
| the boot description: with the same six `jtag` rows, `enable_jtag_gpio` is written on a development card and not on a release card | the kinds of card a setting is written on ignored |
| the manifest check's clauses | a controller's GPIO bank placed in another unit; a table with rows and no holder; a device with other states whose holder has no `pins` grant for it; `gpio` rows on two controllers of one domain; a `pins` grant that names a device with `default` alone |
| the chokepoint: a module outside the kind's register module that calls a GPFSEL accessor fails the build | the rule's entry for the kind removed |
| with the importer: a group of each form decodes to its rows; a tree and a record that both state one pin, and a group that names GPIO 14, are refused | a cell count not checked; the group's parent not checked |

**Fuzz targets**, landing with their parsers: the `pins` tree's `ctl`
and walk names, in the trees' one target; the record's `pins`, in the
platform record's; the `pins` record, in the device record reader's;
`erx_pins_rp1:plan/2` over arbitrary readings, with the `rp1` kind,
whose readings come from a device on a bus; `erx_dt`'s pin query and
each group decoder, with the importer.

**QEMU `raspi4b`.** QEMU runs no firmware, so on the model these pins
are set by the driver alone. Whether the model keeps what the plan
checks is unverified. The readings on record are of registers that
nothing had written
([research-rpi4-header-probe.md](research-rpi4-header-probe.md)), so
they show no register taking a write, and a register the model does not
keep would leave its devices unset at every boot of the model.

A probe therefore runs on the model before the pin driver lands. For
each kind of register the plan checks, it writes a value other than the
one it read, on pins the model's console does not use, and reads it
back: a function field of GPFSEL, a pull field of
GPIO_PUP_PDN_CNTRL, a bit of each edge enable, and GPSET and then GPCLR
on a pin it has made an output, each read at GPLEV. Its result is a
research record that names the QEMU version
([research-qemu-raspi4b-pins.md](research-qemu-raspi4b-pins.md)). For a field the model does
not keep, one of two things is decided from that record before the
suite's cases are written:

* The rows that need the field are not the model's. The suite builds
  the model's image from the board's table without them, from a list
  that names each row left out and the reading that excludes it, and
  its report shows each of them as not run on the model. The board's
  checks below are then those rows' only test.
* Or the model is changed to keep the field. QEMU is a pinned tool that
  erXos does not change, so that is a decision of its own, and until it
  is made the first holds.

No build of the pin driver skips or weakens a check for the model, and
no case passes by comparing a reading with what the model returned.

The cases, over the rows the model keeps:

* After boot `/proc` shows UART0's four pins and the host link's two
  with the table's functions. Seeded fault: UART0's rows removed from
  the record, which must show the pins as inputs.
* Ending the pin driver's process leaves the same registers after its
  restart.
* A device left unset that the normal configuration alone uses boots
  rescue. The suite's manifest grants UART0's line to a domain outside
  rescue, and the register module is seeded to skip one write of
  UART0's pins: the machine boots its rescue configuration within that
  boot, the login names the pin, and that domain does not exist.
  Seeded fault: UART0 marked as no one's, under which the boot is
  normal and the domain starts with its line's pins unset.
* A device that rescue uses stops the boot: with the skipped write in
  the host link's pins, the system release does not boot and the kernel
  log holds the pin driver's line naming the pin.

The GPIO cases are the header design's.

**The Raspberry Pi 4 board**, by hand:

* The settings table against the board: the header probe
  ([research-rpi4-header-probe.md](research-rpi4-header-probe.md))
  reads GPFSEL1 and GPFSEL2 before erXos writes a pin, and GPIO 14 and
  15 must hold ALT5 and, on a development card, GPIO 22 to 27 ALT4.
* With the root's write deleted, GPFSEL3 reads `0x00000fff` through
  `/proc`, and the Bluetooth controller answers its reset as it does
  after the root's write; with the Wi-Fi rows, the pull register reads
  as the rows state. Seeded fault: a card whose record lacks UART0's
  rows, on which the controller must not answer.
* With `config.txt`'s `gpio=` lines deleted, the header's bus pins and
  the host link's read through `/proc` as the table states, and the
  host tool reaches the host link.

**The Raspberry Pi 5 board**, with its packages: the Ethernet link comes
up after `reset` and `default`; USB ports have power with GPIO 42 and 43
in `vbus1`, and `/proc` shows their pads with output disable clear and
input enable set; the pulls and the `INOVER` fields of those two pins,
which no row states, are recorded. With the SD slot's states: ending
the pin driver's process while the card is in a state other than
`default` changes no register, read through `/proc` before and after.

## Performance

A plan is arithmetic over a few words. The start adds two reads and at
most one write of each of a controller's registers to the system
release's start, before the domain service; the change that lands it
gives the boot time before and after (`tools/erx bench`), as any change
to the boot path does.

## Before and after

What a maintainer must know, across the system:

| | Today | With this design |
| --- | --- | --- |
| statements of a pin fact | the header map; its `onboard` rows; `erx_rp1`'s code for RP1 GPIO 32, 42 and 43; the host link overlay's pin group | the pin table |
| what says where the console is | rows that name the console's device, checked against the chip's table alone | the same rows, checked also against the settings the build writes for the firmware |
| writers of pin registers | the firmware; the root at boot; the GPIO driver (planned); `erx_rp1` | the firmware, for the console and JTAG; `erx_pins` |
| rules that keep writers apart | "two writers, separated by time"; the root's core has no field for header pins; the GPIO core writes only `000` or `001`; read-modify-writes carry another writer's fields | one process per controller |
| cores that compute a function field | `kernel/core/bcm2711_pins.c` in C, `erx_gpio_core` in Erlang (planned), `erx_rp1_core` | one `plan/2` per kind |
| how a write is checked | the root compares the words it wrote with a second reading | the planner, run again over a second reading |
| a pin that does not take its setting | the root reports it, and every domain starts | the release boots the larger of its two configurations whose devices are set, or none |
| what a writer can set | functions on the board; functions never on the header at run time; no pulls off the header | function, pull and level, wherever the table says |
| a driver that drives a line | its own register writes (`erx_rp1:phy_reset/1`) | a state name |
| what remembers a device's pins | nothing; the root writes once | nothing; the state is read from the registers |
| a unit needed by two holders | the root at boot and the GPIO driver's domain after | one holder, which is also the boot-time writer |
| the root's mapping of the GPIO page | writable for the system domain's life, a recorded residual | none |
| a new board with pins | rows, and a new C core and root step for its chip | rows, and one Erlang kind module per new chip |

Deleted: `kernel/core/bcm2711_pins.c` and its header, the Fiasco shim
`bcm2711_pins.c`, the root's `board_pins` step and report line, the
chokepoint group for the core, the manifest's `onboard_pins` table and
its range rule, the pin lines of `hw/dts/raspi4b-uart3.dtso`,
`config.txt`'s `gpio=` lines, the
separate `erx_gpio` application and the `PINS` mask of the header
design, and `erx_rp1`'s pin registers and `phy_reset/1`.

Added: state names in the table and a name for each controller; the
boot description's settings table and the reader's check of the
firmware's rows against it; the manifest's `pins` table and the `pins`
record; `erx_pins` with one kind module per chip; the `pins` service;
five clauses of the manifest check; one inspection path; which
configurations use each device, derived into the record, and with it a
second reason for the rescue configuration. Planned with
its first consumer and not before: the tree importer. Not designed
here: one pin served both as plain GPIO and as a device's.

## Alternatives considered

* **Read each device's pin groups from the live tree at boot,** as
  FreeBSD does. The tree is untrusted and a pin's owner is authority, so
  each device would need a build-proved bound on the pins it may take;
  that bound is the table, and the tree would then add only what the
  table already says. It would also make the Pi 5's pins depend on which
  tree the board boots, a choice still open
  ([design-platforms.md](design-platforms.md#the-pi-5s-device-tree-and-its-license)).
* **Keep the root's boot write beside a run-time driver.** Two writers
  of one page need a rule that keeps them apart, two cores compute the
  same fields in two languages, the root's cannot set pulls, and the
  unit has two would-be holders. Nothing needs a pin before the system
  release runs except the console.
* **A claim per driver:** each driver asks the pin driver for its pins
  at its own start, as OpenBSD's drivers call `pinctrl_byname`. A driver
  that forgets has no pins, the vault's TPM driver would depend on
  another service at every start, and a pin's state would depend on
  which drivers happen to run. Applying every default at the pin
  driver's start removes the request.
* **Run-time claims on any pin, first come first served,** as Linux
  resolves conflicts. Which driver wins would depend on start order.
  With one row per pin the conflict cannot be written; only a plain GPIO
  pin is decided at run time, between grants, and the later one is
  refused with `ebusy`.
* **States in each device's record.** The conflict check would have to
  gather them, and the pin driver would have to trust what each client
  sends.
* **A state that ends with the process that selected it,** the device
  going back to `default`. The pin driver would have to remember every
  selector. Its own restart loses that memory, and it must then either
  write `default` under a device in use, which can change a card's
  supply or signalling voltage in the middle of a transfer, or stop
  every consumer first, in other domains too. A selector in another
  domain would need a handle whose close releases the state. The one
  thing it buys, a chip not left in reset by a driver that died, the
  driver's own restart already gives.
* **Find the console's pins in the registers at start,** leaving alone
  any pin found carrying a console signal. QEMU runs no firmware, a
  table that disagrees with the board would go unnoticed until a boot,
  and property 8 needs the answer when the manifest is checked.
* **Let the driver of a device that is not set start, and fail on its
  chip.** Only some drivers would notice. An SPI controller clocks bytes
  in whether or not its pins reach the header, and would return them as
  data. So nothing that would use a device left unset starts.
* **A readiness answer for each device,** asked before every give and
  every driver start, so that the machine runs without the one device
  whose pins could not be set. Gives are planned in the domain library,
  so the answer would have to be carried into every creation's plan; a
  driver already started would need a stop that no later start can
  undo; and each later start would need the question again. The
  release's two configurations already say which domains a boot
  creates, and choosing between them is one fact, settled once, before
  any domain exists.
* **Stop the boot for any pin that differs.** One rule and no
  configuration. But the stop comes before the reset count advances, so
  it is never counted: a fault at the pins of a device the machine can
  run without, the Bluetooth line's, would end the machine at every
  boot with no rescue.
* **Let only the failed controller's pin driver stay down,** and stop
  the boot only for a controller that carries pins the boot itself
  needs. The Raspberry Pi 4 has one controller for all of its pins, so
  there the rule decides nothing. And a release that boots on gives
  every device to its holder as before, so leaving a controller's
  devices unserved would again need the readiness answer.
* **Leave down only the domain a device left unset is for,** as a
  domain beyond its restart intensity is left down. It keeps more of
  the machine running than rescue does. It costs a condition in the
  domain service's creation of each domain and, for the pin driver's
  restarts, the set of domains the boot left out, where a configuration
  is one fact. It is the next step if boards show such faults
  ([Decisions](#decisions), 1).
* **Have a driver in the pin driver's own domain select `default` as it
  starts,** so that a line whose pins are unset breaks alone, as the
  line service already leaves a line whose driver does not start. It is
  the claim per driver again, for some drivers.
* **Write `default` to every device at the first start, and leave a
  device alone at a later one.** The pin driver would need to know which
  start it is, a fact kept outside the process, and "first" is not the
  property that matters. What makes a start's write safe is that no
  driver selects for the device, which the table says of every device
  with `default` alone, at every start.
* **Stop every consumer before the pin driver restarts,** so that the
  restart could write freely. It puts driver-control calls into other
  domains on the pin driver's recovery path. A start that writes no
  device with other states needs none.
* **Roll back a plan after which a pin differs.** The values before it
  are no safer, and their writes can fail the same way.
* **One process for every controller of a domain,** so that a state
  could span two controllers. No device needs such a state, and a pin
  number would then need its controller in every request.
* **A GPIO grant for every line a driver drives.** A reset line's level
  at rest is a board fact, and a GPIO pin's idle state is input; a
  driver would send levels the board's table never saw; and a restart
  of the pin driver would float the line. A state has none of the
  three.
* **A pin driver domain of its own on the Pi 4.** It keeps the tree's
  server out of the system domain. It costs a domain, a start order rule
  between domains, and a system domain that waits on a configured
  domain for the Bluetooth line and the host link, where the system
  domain's cost is the root task's authority for the trees' code
  ([Decisions](#decisions), 2).
* **Keep `config.txt`'s `gpio=` lines beside the pin driver.** They are
  a second writer of the bus pins, redundant on the board and without
  effect under QEMU, kept only for a boot that runs no system release.
* **Build the tree importer for the Raspberry Pi boards.** Their wired
  pins number about ten and about twenty-five, and rows a tool derives
  from a GPL-licensed tree would ship inside the image's manifest.

## Decisions

1. **The pin driver's start replaces the root's boot write.** The
   system domain's pin driver sets the on-board pins, UART0's among
   them, with every other device's pins ([At start](#at-start)), and
   the root writes no pin
   ([design-header-io.md](design-header-io.md#decisions), 1;
   [design-bluetooth.md](design-bluetooth.md#decisions), 5). The root's
   write is proven on the board, so the driver's parity test is the
   board check of [Verification](#verification): with that write
   deleted, GPFSEL3 reads the same word and the Bluetooth controller
   answers its reset.

   A pin that does not take its setting keeps what would use its device
   from starting, on every kind of build, where the root's write
   reports it and lets every domain start:

   * A device that only domains outside rescue use, on the Pi 4 UART0's
     four pins, makes the boot a rescue boot: the console and a login,
     with no network and no user domain, in that boot and in every boot
     until the pin takes its setting. The machine does not run on
     without Bluetooth alone.
   * A device that the system release or a domain of the rescue
     configuration uses, on the Pi 4 the host link's two pins, stops
     the boot. The stop comes before the reset count advances, so it
     repeats at every boot and rescue never follows it. Only repairing
     the board, or writing its card with a table that fits it, ends
     that. A `required` domain that cannot start before the slot writer
     runs ends the machine the same way.
   * A device that no domain holds costs a log line.

   When this can happen bounds the cost. A function or pull field that
   does not keep its write means a chip that does not work, a model
   that lacks the register, or a table wrong for the board, which a
   trial boot meets before its slot is committed and a new card meets
   at its first boot. An output can also be held at the other level by
   what is wired to it. The Pi 4's rows are signals, pulls and plain
   GPIO, and none drives a level.
2. **The system domain holds the Pi 4's pin controller and serves
   `/dev/gpio` from it.** Property 8's pin clause allows no other
   holder: a unit whose registers can put a signal of the console's or
   the host link's device on a pin, by the chip's pin table and
   whichever pins the rows use, is held by no domain or by the system
   domain ([design-system.md](design-system.md#the-manifest)). So no
   start order between domains stands before the Bluetooth line and the
   host link, and what else such a holder may hold needs no rule. The
   cost is authority: the code that reads GPIO clients' requests runs
   with the authority of the root task, and its fault resets the
   machine ([Security](#security)).
3. **The boot description writes no `gpio=` line.** The pin driver sets
   the header's bus pins and the host link's, and the firmware's
   settings that remain are `enable_uart` and `enable_jtag_gpio`
   ([What the firmware leaves](#what-the-firmware-leaves)). The bus
   pins stay inputs for the seconds until the system release starts,
   and a boot that runs no system release, the probe card or a native
   partial boot, finds them and the host link's pins unset.
4. **The Raspberry Pi boards' rows are written by hand, and the tree
   importer waits for a board that needs it:** the first whose tree the
   build compiles under a permissive license and whose wired pins
   number more than a screenful
   ([Rows from a board's tree](#rows-from-a-boards-tree)). A row whose
   only source is a GPL-licensed tree carries that license question
   whether a tool or a person copies it, and a facts record does not
   answer it. The Pi 4's rows come from the chip's documentation, the
   schematics and board readings. The Pi 5's BCM2712 rows have no such
   source, so shipping them waits on the decision about that board's
   tree
   ([design-platforms.md](design-platforms.md#the-pi-5s-device-tree-and-its-license)).

## References

* FreeBSD releng/15.1, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
  BSD-2-Clause: `sys/dev/fdt/fdt_pinctrl.c` (SHA-256 `cb1f6048...`),
  `sys/dev/fdt/fdt_pinctrl_if.m` (`8e1e6952...`),
  `sys/arm/broadcom/bcm2835/bcm2835_gpio.c` (`783b718c...`),
  `sys/arm/allwinner/aw_gpio.c` (`3eaa7d34...`),
  `sys/arm64/rockchip/rk_pinctrl.c` (`9246b99e...`).
* OpenBSD 7.8, `sys.tar.gz` (SHA-256 `e24904ca...`):
  `sys/dev/ofw/ofw_pinctrl.c`, `sys/dev/fdt/bcm2835_gpio.c`,
  `sys/dev/fdt/iicmux.c`. NetBSD, branch `netbsd-10`, commit
  `24625588f33e5f3456100fbb0cb24e89a6c62a52`:
  `sys/dev/fdt/fdt_pinctrl.c`, `sys/dev/fdt/fdtbus.c`,
  `sys/arch/arm/broadcom/bcm2835_gpio.c`.
* Linux v6.12, documentation only, read through a clean-room facts
  record: `Documentation/driver-api/pin-control.rst` (SHA-256
  `d59bde2d...`),
  `Documentation/devicetree/bindings/pinctrl/pinctrl-bindings.txt`
  (`06a6ed4e...`), `pincfg-node.yaml` (`00fe2a6a...`),
  `brcm,bcm2835-gpio.txt` (`78fe1e79...`).
* dt-schema v2026.09, commit `01b5073abbeb732a04c22f01ac0370b951b20c0e`,
  BSD-2-Clause: `dtschema/schemas/pinctrl/pinctrl-consumer.yaml`
  (SHA-256 `8aad0c22...`). The Devicetree Specification v0.4 defines no
  pin control.
* Zephyr v4.3.2, commit `28af05ca658cbacf745fd5b099566311c58ccb1d`:
  `include/zephyr/drivers/pinctrl.h`, `drivers/pinctrl/common.c`,
  `doc/hardware/pinctrl/index.rst`. Hubris, commit
  `969bac2bf47c98710842eb232fdd4a9c54e7dd7f`:
  `build/stm32xx-sys/src/lib.rs`, `drv/stm32xx-sys/src/main.rs`,
  `drv/stm32h7-spi-server-core/src/lib.rs`. Embassy,
  `embassy-stm32-v0.4.0`: `embassy-stm32/src/usart/mod.rs`. 9front,
  commit `239c052af95ccd65dccc8610ff75de0c45986a45`:
  `sys/src/9/bcm/devgpio.c`. sDDF 0.7.0: `docs/design/design.tex`. QNX
  SDP 8.0, "Customizing a BSP", Startup.
* Raspberry Pi firmware distribution, tag 1.20260915, commit
  `6f0881cba8bea8ec24956a5718714730e9936ec5`, read through a clean-room
  facts record: `boot/bcm2711-rpi-4-b.dtb` (SHA-256 `75761b73...`),
  `boot/bcm2712-rpi-5-b.dtb` (`a5165cb5...`).
* BCM2711 ARM Peripherals, release 4, as
  [design-header-io.md](design-header-io.md#references) cites it:
  section 5.2 for the function and pull registers, 5.3 for Table 94.
