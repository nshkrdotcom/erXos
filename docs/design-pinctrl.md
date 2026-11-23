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
  name for a pin register. At its start it makes the registers equal to
  the table. Afterwards it writes only for a state name or a GPIO
  request that the table and the asker's grant allow.
* **Defaults need no request.** Every device's `default` state is
  applied when the pin driver starts, whether or not the device is
  driven. A driver finds its pins set, and there is no claim protocol
  between drivers.
* **Every write is planned whole, then applied.** A pure function takes
  the registers as read and the settings wanted and returns the register
  writes, or a refusal that writes nothing.
* **A driver never sends a function, a pull or a level.** It selects a
  state by name, and the table says what the state means. A reset line,
  a power enable or a signalling voltage is a second state of the device
  that owns the pin.
* **The console's pins are the firmware's.** The kernel prints before
  any driver runs, so the firmware sets the console's pins and no row
  for them reaches the pin driver.
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
name (Zephyr, Hubris's SPI routings); pin ownership is checked when the
description is built (Hubris, Embassy); a pin goes back to rest when its
holder ends (Embassy's drop); state is a file to read and control a file
to write (9front). What it avoids, each seen above: no ownership at all;
two writers of one register field; a group left half applied;
permissive `ctl` parsing; and a device tree, which firmware supplies, as
the authority over who owns a pin.

### The boards

**Raspberry Pi 4.** The BCM2711's GPIO block is pin controller and GPIO
controller in one page, with no lock
([design-header-io.md](design-header-io.md#the-hardware)). Three sets of
pins need setting:

* The header's bus pins and the host link's, which the firmware sets
  from `config.txt`'s `gpio=` lines.
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
its start for every device's `default` state, and afterwards only for a
state name or a GPIO request that the table and a grant allow. Each
write is a pure function of the registers as read and the settings
wanted.

Everything below follows from those three sentences.

**From source to register.** A pin fact takes one path:

1. The chip's documentation gives `hw/pins/<kind>.txt`; the board's
   wiring gives the record's `pins`. The record reader checks the two
   against each other and refuses a table that breaks a rule.
2. The packer writes the table into the manifest, and the manifest check
   proves its clauses about units, holders and grants.
3. At boot the domain library writes each controller's rows into its
   holder's boot page as one `pins` record.
4. The pin driver reads the registers, plans, writes, reads back and
   reports.
5. At run time a request names a state or a GPIO pin; the driver checks
   it against the table and the holds, and plans and writes as in step
   4.

No step reads a pin fact from anywhere else, and no later step checks
an earlier one's output again.

### Invariants

| Invariant | Held by |
| --- | --- |
| **PC1.** A pin has at most one owner | one row per pin; the reader refuses a second |
| **PC2.** Once the kernel runs, only the pin driver writes a pin controller's registers | a controller's devices are one unit with one holder; only the kind's register module names the registers |
| **PC3.** erXos never writes the console's or JTAG's pins | their rows are not in the driver's record, and a plan keeps every field it has no pin for |
| **PC4.** A plan is applied whole or not at all | `plan/2` returns every write or a refusal |
| **PC5.** A client changes a pin only to a setting the table lists, for a pin in its scope | a request carries a state name or a GPIO `ctl` line, never a function or a register; the manifest check proves each grant's scope |
| **PC6.** A device's pins are in `default` before its driver starts | the pin driver starts before the device drivers of its domain; the system release runs before any configured domain; a controller in a configured domain serves that domain's devices alone |
| **PC7.** A pin taken for a client goes back when the client ends | the one process monitors every holder and selector |
| **PC8.** What `/proc` shows a pin to hold is what its registers hold | read from the registers, never from the table |

### The pin table

The platform record's `pins` lists the board's **pin controllers**. Each
entry has:

* its **kind**, the entry's `soc`, which names the SoC pin table it is
  checked against, `hw/pins/<kind>.txt` (`bcm2711`, later `rp1` and
  `bcm2712`). That file, written from the chip's documentation, lists
  each pin, the signals it can carry, and which peripheral block owns
  each signal;
* its **devices**, the entry's `controller`: the devices whose registers
  set its pins' functions, pulls and levels. On the BCM2711 that is one
  device. On the BCM2712 it is a pin controller and the GPIO bank beside
  it; on RP1 the IO-bank and pad blocks;
* its **rows**, at most one per pin.

A row names a pin and its **owner**, which the record writes as the
row's `use`:

| Owner | Meaning | Who sets the pin |
| --- | --- | --- |
| a device of the record, by its path or, for a part of a PCIe function, its part's name | the pin carries that device's signal, or is a line that device's driver drives | the pin driver, from the row's settings |
| `gpio` | a plain GPIO pin, served to whoever is granted it | the pin driver, for the grant that holds it |
| the console's device, or `jtag` | set before the kernel runs | the firmware; never erXos |
| `reserved`, or no row at all | nothing touches the pin | nobody |

A device's row carries a **setting**: a `function`, which is one of the
pin's signal names from the SoC table, `in`, or `out` with a `level` of
0 or 1; and optionally a `pull`, `none`, `up` or `down`. A setting
states only what it names: a row without a pull leaves the pull as it
finds it, as a device tree group that names no bias does. Drive strength
and slew rate are not in the vocabulary, since no pin of a driven device
needs them; a property is added with the first row that needs it.

**States.** A row may give further settings under state names:

```json
{"gpio": 32, "use": "eth", "function": "out", "level": 1,
 "states": {"reset": {"level": 0}}}
```

This is RP1's GPIO 32, the reset line of the Ethernet PHY, owned by
RP1's part `eth`: high in `default`, low in `reset`.

The plain setting is the device's `default` state. A device's states are
the names its rows use, and each state is whole: every pin of the
device, with the `default` setting overlaid by what the state names. So
a state is a value, switching between two states needs no history, and
the order of switches does not matter.

**The Raspberry Pi 4's table** is one entry of kind `bcm2711`: its
header map's rows and its on-board rows, one row form in two lists
([design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header)).
The on-board rows take pulls and states like any row.

### What the build refuses

The record reader checks the table and refuses, naming the row:

* a pin on two rows, a pin the kind's table does not list, or an owner
  that is not a device or part of the record;
* a function the pin does not carry, or that is a signal of another
  device than the row's owner;
* a `level` without `out`, a setting on a `gpio` or `reserved` row, or a
  state on a row that is not a device's;
* a device missing a signal its peripheral cannot work without, or
  carrying one signal on two pins, in any state;
* more than `pin_states_max`, 8, states for one device, or a state name
  that is not an identifier.

The manifest check adds, naming the unit:

* **The devices of one controller entry lie in one unit.** A pin's
  function and its level are then written by one holder, whatever the
  chip's split into blocks.
* **A controller with a row for the pin driver has a holder.**
  Otherwise the table would be applied by nobody and a chip would be
  silent with no diagnostic.
* **Property 8's pin clause**, unchanged: a unit whose registers set a
  pin of the console's or the host link's device is held as
  [design-system.md](design-system.md#the-manifest) says
  ([Placement and boot order](#placement-and-boot-order)).
* **A device with rows on a controller a configured domain holds is
  held by that domain**, so no start order between domains is ever
  needed ([Placement and boot order](#placement-and-boot-order)).
* A `gpio` grant's `pins` outside the `gpio` rows of its server's
  controllers; a `pins` grant's `devices` that own no row there, that
  the grantee does not hold, or that another `pins` grant names.

### What is generated from it

1. **The manifest's `pins` table** (`abi/manifest.txt`): the rows of
   every controller, each state's setting spelled out, in pin order. It
   replaces `onboard_pins`.
2. **The pin driver's record.** For the holder of each controller the
   domain library writes one `pins` record
   ([design-fiasco.md](design-fiasco.md#device-records)): the
   controller's device index, the state names its rows use, and its rows
   in a packed layout that `abi/erx_abi.txt` declares, each a pin, its
   owner (a device row's index, or the mark for `gpio`), a state, a
   function number of the kind, a pull and a level. Rows of the
   firmware's pins and `reserved` rows are left out. The record is the
   driver's whole table, so it has no setting for a pin it must not
   write. It is a word of the holder's boot page, which
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
4. **Which bus devices are driven**, and **who may hold the
   controller**, as the header map already derives them
   ([design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header)).

## The pin driver

`erx_pins` is one application. It runs one process for each controller
its domain has a `pins` record of, over three modules in the shape of
every erXos driver ([style](style.md#functional-core)):

| Module | Decides or does |
| --- | --- |
| `erx_pins_core`, pure | from the table and a request, the settings wanted: a device's state, a GPIO pin's `ctl` line, a pin's idle setting; who holds what, through `erx_hold` ([design-header-io.md](design-header-io.md#holding-and-granting)) |
| `erx_pins_<kind>`, pure | **the plan**: from the registers as read and the settings wanted, the register writes; from a level or event register, the pins' levels and the pins that fired |
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
erx_pins_KIND:plan(Read, Wanted) -> {ok, Writes} | {error, {Pin, Reason}}
```

`Read` is the value of each register the wanted pins have a field in.
`Wanted` is a list of pins with their settings, a function being a
number of the kind, `in` or `out`. `Writes` is a list of registers and
values. The function is total and writes nothing itself:

* **Whole or nothing.** A pin the kind does not have, a function number
  outside the kind's range or a level without `out` refuses the whole
  plan.
* **Only what differs.** A register whose planned value equals its
  reading is not in `Writes`. A plan over pins already set is empty, so
  applying the table twice writes once, and a restarted driver glitches
  no line.
* **Only the wanted pins' fields.** Every other field of a register
  keeps the value read. The console's pins have no row in the driver's
  record, so no plan can name them, and this rule keeps their fields
  when a neighbour in the same register changes.
* **An order that drives nothing unasked.** Pulls first, then output
  levels, then functions, each register once.

Applying is the register module's: write `Writes` in order, read the
same registers again, and compare with the plan. The process then knows
each pin as `set` or `differs`.

Kinds differ only here. The `bcm2711` kind plans the function field of
GPFSEL (3 bits a pin, register `pin div 10`), the pull field of
GPIO_PUP_PDN_CNTRL (2 bits a pin, register `pin div 16`), and GPSET or
GPCLR for a level. The `rp1` kind plans each pin's `CTRL` (`FUNCSEL`, and
the output overrides for `out`) and its pad
([design-rp1.md](design-rp1.md#pins)). The `bcm2712` kind waits for a
facts record of its registers.

### At start

The driver reads the registers of every pin in its record, plans one
whole plan, applies it and reports:

* each device's pins in its `default` state;
* each `gpio` pin in its **idle state**: input, no pull, no edge
  detection, the setting that drives nothing
  ([design-header-io.md](design-header-io.md#devgpio)).

It reports one log line: how many pins it set, how many already agreed
and which pins differ after the write. A refused plan, which a table the
build checked cannot produce, writes nothing and is reported as refused.
In neither case does the start fail: only the chips on those pins fail,
with their own diagnostics, and the machine boots.

### States at run time

```
erx_pins:select(Device, State) -> ok | {error, enoent | ebusy | eio}
```

`Device` is a device's manifest row index, the word its own record
carries. The driver plans the state's settings for the device's pins and
applies them. `enoent` is a state the table does not give the device;
`eio` a plan whose write read back otherwise.

* **Who may select.** A process of the pin driver's own domain, for any
  device of the table; another domain only through a `pins` grant whose
  scope names the device ([Interfaces](#interfaces)).
* **A state lasts while its selector lives.** The driver monitors the
  process or grant that selected a state other than `default`. When it
  ends, the device returns to `default`. A driver that dies holding a
  chip in reset therefore releases it.
* **A line a driver drives is a state, not a GPIO request.** RP1's
  Ethernet driver resets its PHY by selecting `reset`, waiting 5 ms and
  selecting `default`. A card's signalling voltage or a radio's power
  enable is the same. The driver's code names a state, and the board's
  table says which pin and which level.
* **Sleep states and switched buses.** A device whose pins change for
  low power, or a bus whose signals move between two pin pairs, lists
  each arrangement as a state over the pins it owns. No erXos driver
  selects one yet.

### Plain GPIO

A `gpio` pin is served through `/dev/gpio` exactly as
[design-header-io.md](design-header-io.md#devgpio) describes: one
directory per pin of the grant's scope, `ctl`, `value` and `event`, one
holder at a time, and the pin back in its idle state when its hold
ends. The `ctl` vocabulary is `in`, `out 0`, `out 1`, three pulls and
four edges, so a GPIO client cannot ask for an alternate function.

### A pin that is sometimes a device's

Some connector pins serve two uses on one machine: GPIO 18 is plain GPIO
until a fan needs PWM on it. A device state other than `default` may
name a pin whose row is `gpio`, a **borrowed** pin, and the `gpio` row
lists the device, the state and the setting. Selecting that state takes
the pin's hold as an open of its files does: `ebusy` if a grant or
another device holds it, every borrowed pin or none. While the state is
selected, opening the pin's GPIO files answers `ebusy`. When the device
leaves the state, or its selector ends, the pin returns to its idle
state.

So a pin has one holder at every moment, decided by the one process that
writes it, and a wired pin is never contended: only a `gpio` row can be
borrowed, and `default` never borrows. The first consumer is PWM
([design-header-io.md](design-header-io.md#pwm)); borrowing is built
with it.

## Where each fact comes from

| Fact | Source | Why there |
| --- | --- | --- |
| which signals a pin can carry, and their codes | `hw/pins/<kind>.txt`, from the chip's documentation | a fact of the chip, the same on every board |
| a pin's owner | the board's pin table | authority: the build proves who can reach the console's wires |
| a pin's setting in each state | the same row | wiring, the same at every boot |
| which states exist | the same rows | so the conflict check sees every state of every device at once |
| who may select a device's state or hold a GPIO pin | the manifest's facet rows | grants are the manifest's |
| what the pins hold right now | the registers, read by the pin driver | never the table's claim |

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
  from the tree.
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
  has two writers.

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
([Open decisions](#open-decisions), 4).

### What the firmware leaves

The driver assumes nothing about the pins it finds. Its first plan is a
function of the registers as read, so a pin the firmware already set
costs no write and a pin it left wrong is corrected. Three things remain
the firmware's:

* **The console's pins and JTAG's** are set before the kernel runs, by
  `enable_uart` and `enable_jtag_gpio` on the Raspberry Pis, and are
  never written by erXos. A board whose firmware does not set its
  console's pins has no early console, and that is its kernel platform
  layer's to solve.
* **A pin with no row** is never written, and its field is carried
  through every write of the register it shares.
* **The registers after hand-over.** The driver's read-modify-writes are
  sound only while nothing else writes the controller. The design
  requires that of the firmware, as
  [design-header-io.md](design-header-io.md#the-construction-one-map-of-the-header)
  already does; the board probe's readings a minute apart are evidence,
  not proof.

`config.txt`'s `gpio=` lines are no part of this design: with or without
them the driver's plan leaves the pins as the table says
([Open decisions](#open-decisions), 3).

### A machine's own choices

* **An app adds no pin.** It reaches pins through services: `gpio` with
  a `pins` scope, `i2c1`, `spi0`. Its declaration names services the
  board's `apps` row offers
  ([design-packaging.md](design-packaging.md#the-declaration)), and
  admission checks them. The table already gives those pins to those
  services, so installing an app changes no row.
* **A user who wants a connector pin for something else** uses a state
  that borrows it ([above](#a-pin-that-is-sometimes-a-devices)). The
  board's table lists what may borrow which pin, so the choice is made
  at run time among uses the build checked, with no new image and no
  reboot.
* **A different default** (the header's I2C on other pins) is a
  different record, and so a different image.
* **Not a device tree overlay.** The firmware would merge it into the
  tree, which is never read for pins; its files come from the
  firmware's distribution under the GPL; and `config.txt` is a file the
  build writes.

## Placement and boot order

**One holder writes a controller.** The kernel gives registers by whole
pages ([design-system.md](design-system.md#devices)), so whoever holds a
pin controller can write every pin in it. Its unit therefore has one
holder, and the pin driver runs there.

**The system domain holds a pin controller that sets the console's or
the host link's pins**, as property 8 allows, and its release starts
`erx_pins` before every device driver of the release. On the Raspberry
Pi 4 that is the `gpio` unit. The BCM2712's two controllers go to the
system domain as well, whether or not they set the console's pins,
which no source read here says: the SD slot's pins must be set before
the storage domain starts. Three things follow without a rule:

* Every configured domain is created after the system release runs, so
  the SD controller's, the buses' and the vault's TPM's pins are set
  before their drivers start. No bus driver depends on any domain but
  the system domain, on which every domain already depends.
* UART0's pins are set before the line service opens the line to the
  Bluetooth controller, by the start order of the system release.
* Nothing must be set "before any domain runs" except what the firmware
  sets: the console's pins.

**A controller inside another domain's unit is driven there.** RP1's pin
blocks are parts of RP1's function, so the `rp1` domain runs their
`erx_pins` under its unit supervisor, after `erx_rp1` and before the
parts' drivers ([design-rp1.md](design-rp1.md#pins)). Every device with
rows there is a part of the same unit, which the manifest check holds
to.

**Pin controller and GPIO controller.** On the BCM2711 they are one
device. Where they are two, the controller entry names both, the
manifest check keeps them in one unit, and one process plans both. No
GPIO driver asks a pin driver to prepare a pin, because they are the
same process.

## Interfaces

**Inside the pin driver's domain:** `erx_pins:select/2` above.

**Across domains,** two services of the pin driver, each an interface
`abi/services` declares and a files tree served through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)):

| Service | Interface | Scope parameter | Mount point | Tree |
| --- | --- | --- | --- | --- |
| `gpio` | `gpio` | `pins`, a set of pin numbers | `/dev/gpio` | one directory per pin: `ctl`, `value`, `event` ([design-header-io.md](design-header-io.md#devgpio)) |
| `pins` | `pins` | `devices`, a set of device rows | `/dev/pins` | one directory per device, named by its row index: `ctl` and `status` |

`/dev/pins/N/ctl` takes one line, `state NAME`, with the answers of
`select/2`; any other line is `einval`. `/dev/pins/N/status` reads the
device's state on its first line and then one line per pin: the pin,
its function, pull and level as read. The `pins` service is built with
the first driver that selects a state from another domain.

**Inspection.** Each pin driver reports to its domain's inspector at
`[domains, D, pins, Controller, Pin]`, a path `abi/inspection.txt`
declares, shown under `/proc/domains/D/pins/`
([design-live.md](design-live.md#the-proc-tree)): the pin's owner (a
device row index or `gpio`), its device's state, the setting wanted, the
function, pull and level its registers hold, whether the two agree, and
for a GPIO pin its holder, edge setting and edge count. A function code
the kind's table has no name for is shown as its number. A value the
driver cannot read is `unknown`, never the table's.

## Concurrency and failure

One process per controller serves one request at a time, so each
register update is one read-modify-write by the only writer of those
registers. A hold's check and its effect are one step of that process
([design-header-io.md](design-header-io.md#holding-and-granting)).

| Event | Result |
| --- | --- |
| a plan is refused | nothing is written; the request answers its error; at start the driver reports and goes on |
| a write reads back otherwise | the pins are marked `differs` and shown so; a `select` answers `eio` |
| the pin driver's process ends | its supervisor restarts it; it reads and plans again, so device pins already in `default` are not written; devices in another state return to `default`, GPIO pins go to their idle state, and old handles answer `eio` |
| a selector or a grant ends | its devices return to `default` and its GPIO pins to their idle state |
| the domain of a controller ends (`rp1`) | the registers keep their values; the restarted domain's driver plans from what it reads |
| the firmware writes the controller after hand-over | a race the design excludes by requirement, not by mechanism |

## Refusals and error results

| Request | Answer |
| --- | --- |
| `select` of a state the table does not give the device | `enoent` |
| `select` whose borrowed pin another holder has; an open of a GPIO pin a device or another grant holds | `ebusy` |
| a `select` or GPIO write that read back otherwise; a handle of an ended driver | `eio` |
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
* **A client can ask only for what the table lists.** A request carries
  a state name or a line of the GPIO `ctl` grammar. None carries a
  function code, a register or a pin outside the asker's scope.
* **The driver cannot plan the console's pins,** having no record of
  them.
* **Untrusted input** reaches three parsers: the `ctl` grammars and walk
  names of both trees; the platform record's `pins`; and, for a board
  that uses it, the tree importer's groups. Each has a fuzz target. The
  live tree's pin properties reach no parser.
* **Text.** State names and signal names are identifiers the build
  checked, and every other value is a number, so the trees and `/proc`
  show nothing a device or a client wrote.
* **Driving a wire** against another driver of it can damage a board.
  That is the wiring's and the operator's, as on any system that offers
  GPIO.
* **On Fiasco** nothing differs: the driver is a driver of its domain
  like any other. The root's lifelong writable mapping of the GPIO page
  goes away with the root's write.

## Verification

**Host tests of the pure cores**, each paired with a seeded fault that
must make it fail.

| Test | Seeded fault |
| --- | --- |
| `erx_pins_bcm2711:plan/2` against the board's reading of GPFSEL3, `0x00000fc0`, wanting UART0's four pins | each field one pin off; a whole-register write, which zeroes GPIO 34 to 39; ALT4 and ALT5 swapped |
| the plan is whole | a plan applied in part when its last pin is refused |
| the plan is idempotent: planning over its own result is empty | the "only what differs" rule removed |
| a neighbour's field is kept: a plan for GPIO 12 and 13 leaves GPIO 14 and 15 as read | a GPFSEL write that is not a read-modify-write |
| pulls: GPIO 34 to 39 as the Wi-Fi rows state them | up and down swapped; a row without a pull writing `none` |
| write order: pull, level, function | the function written before the level, which a model that samples the pin between writes exposes |
| `erx_pins_core` states: `default` overlaid by a state; an unknown state | the overlay dropping a pin the state does not name |
| a state ends with its selector | the monitor removed |
| the start plan: devices in `default`, GPIO pins idle, no firmware pin | a firmware row written into the record |
| with borrowing: `erx_hold`'s exhaustive test gains an event, a select that takes two pins | one pin taken when the other is held |
| the table reader, one table that breaks only each refusal | as each refusal says |
| the manifest check's unit and holder clauses | a controller's GPIO bank placed in another unit; a table with rows and no holder |
| the chokepoint: a module outside the kind's register module that calls a GPFSEL accessor fails the build | the rule's entry for the kind removed |
| with the importer: a group of each form decodes to its rows; a tree and a record that both state one pin are refused | a cell count not checked; the group's parent not checked |

**Fuzz targets**, landing with their parsers: the `pins` tree's `ctl`
and walk names, in the trees' one target; the record's `pins`, in the
platform record's; the `pins` record, in the device record reader's;
`erx_dt`'s pin query and each group decoder, with the importer.

**QEMU `raspi4b`.** After boot `/proc` shows UART0's four pins and the
host link's two with wanted and read functions agreeing, if the model
keeps the function registers; otherwise the case is left out and named.
QEMU runs no firmware, so on the model these pins are set by the driver
alone. Seeded fault: UART0's rows removed from the record, which must
show the pins as inputs. The GPIO cases are the header design's.

**The Raspberry Pi 4 board**, by hand: with the root's write deleted,
GPFSEL3 reads `0x00000fff` through `/proc`, and the Bluetooth controller
answers its reset as it does after the root's write; with the Wi-Fi
rows, the pull register reads as the rows state. Seeded fault: a card whose record
lacks UART0's rows, on which the controller must not answer.

**The Raspberry Pi 5 board**, with its packages: the Ethernet link comes
up after `reset` and `default`; USB ports have power with GPIO 42 and 43
in `vbus1`.

## Performance

A plan is arithmetic over a few words. The start adds one read and at
most one write of each of a controller's registers to the system
release's start, before its device drivers; the change that lands it
gives the boot time before and after
(`tools/erx bench`), as any change to the boot path does.

## Before and after

What a maintainer must know, across the system:

| | Today | With this design |
| --- | --- | --- |
| statements of a pin fact | the header map; its `onboard` rows; `erx_rp1`'s code for RP1 GPIO 32, 42 and 43; the host link overlay's pin group | the pin table |
| writers of pin registers | the firmware; the root at boot; the GPIO driver (planned); `erx_rp1` | the firmware, for the console and JTAG; `erx_pins` |
| rules that keep writers apart | "two writers, separated by time"; the root's core has no field for header pins; the GPIO core writes only `000` or `001`; read-modify-writes carry another writer's fields | one process per controller |
| cores that compute a function field | `kernel/core/bcm2711_pins.c` in C, `erx_gpio_core` in Erlang (planned), `erx_rp1_core` | one `plan/2` per kind |
| what a writer can set | functions on the board; functions never on the header at run time; no pulls off the header | function, pull and level, wherever the table says |
| a driver that drives a line | its own register writes (`erx_rp1:phy_reset/1`) | a state name |
| a unit needed by two holders | open: the root at boot and a GPIO domain after ([design-header-io.md](design-header-io.md#decisions)) | one holder, which is also the boot-time writer |
| the root's mapping of the GPIO page | writable for the system domain's life, a recorded residual | none |
| a new board with pins | rows, and a new C core and root step for its chip | rows, and one Erlang kind module per new chip |

Deleted: `kernel/core/bcm2711_pins.c` and its header, the Fiasco shim
`bcm2711_pins.c`, the root's `board_pins` step and report line, the
chokepoint group for the core, the manifest's `onboard_pins` table and
its range rule, the pin lines of `hw/dts/raspi4b-uart3.dtso`, the
separate `erx_gpio` application and the `PINS` mask of the header
design, and `erx_rp1`'s pin registers and `phy_reset/1`.

Added: state names in the table; the manifest's `pins` table and the
`pins` record; `erx_pins` with one kind module per chip; the `pins`
service; two clauses of the manifest check; one inspection path. Planned
with their first consumers and not before: borrowing, and the tree
importer.

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
  With one row per pin the conflict cannot be written; only a borrowed
  `gpio` pin is decided at run time, and it is refused with `ebusy`.
* **States in each device's record.** The conflict check would have to
  gather them, and the pin driver would have to trust what each client
  sends.
* **A GPIO grant for every line a driver drives.** A reset line's level
  at rest is a board fact, and a GPIO pin's idle state is input; a
  driver would send levels the board's table never saw; and a restart
  of the pin driver would float the line. A state has none of the
  three.
* **A pin driver domain of its own on the Pi 4.** It keeps the tree's
  server out of the system domain. It costs a domain, a start order rule
  between domains, and a system domain that waits on a configured
  domain for the Bluetooth line and the host link
  ([Open decisions](#open-decisions), 2).

## Open decisions

1. **Replace the root's boot write with the pin driver's start.** This
   changes two accepted decisions: the root writes the on-board pins
   ([design-header-io.md](design-header-io.md#decisions), 1) and the
   root sets UART0's pins
   ([design-bluetooth.md](design-bluetooth.md#decisions), 5).
   Recommendation: replace it, with the board check above as its
   parity test. The cost is reworking code proven on the board.
2. **Where the Pi 4's pin controller lives once it serves `/dev/gpio`:**
   the system domain, or a trusted domain of its own, the header
   design's candidate. Either is in the console's trusted base.
   Recommendation: the system domain, and then tighten property 8's
   clause to "is the system domain's", as its UART clause reads, which
   also settles the open question of what else such a domain may hold.
3. **`config.txt`'s `gpio=` lines on the Pi 4.** Deleting them changes
   the accepted "the firmware sets the bus pins". With the pin driver
   they are redundant on the board and have no effect under QEMU; without
   them the header's bus pins stay inputs for the seconds until the
   system release starts, and a boot that runs no system release (the
   probe card, a native partial boot) finds them unset. Recommendation:
   delete them with the pin driver's landing, unless such a boot needs
   the host link.
4. **When to build the tree importer, and whether the Raspberry Pis use
   it.** Rows the build derives from a GPL-licensed tree would ship
   inside the image's manifest, which is a license question as well as
   a technical one. Recommendation: hand-written rows for both boards,
   from the datasheet and the facts records, and the importer with the
   first board whose tree the build compiles under a permissive license
   and whose wired pins number more than a screenful.

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
