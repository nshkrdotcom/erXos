# RP1, the Raspberry Pi 5's I/O controller

RP1 is the chip that carries most of the Raspberry Pi 5's peripherals:
the Ethernet controller, two USB 3 host controllers, six UARTs, the
header's GPIO, I2C and SPI, and more. It sits on the board as one PCIe
function behind the BCM2712's `pcie2` bridge, and every peripheral is a
block of registers at a fixed offset in that function's BAR 1. This
design gives RP1 to one domain as one unit, names each peripheral a
driver needs as a **part** of the function, routes each part's
interrupt by its own MSI-X table entry, and specifies the Ethernet
controller's driver and how the USB hosts reuse the xHCI stack. The
bridge that reaches RP1 is [design-pcie.md](design-pcie.md#the-bridge-seam)'s,
the board's boot and devices are
[design-platforms.md](design-platforms.md#raspberry-pi-5)'s, and Fiasco's
part is [design-fiasco.md](design-fiasco.md#the-raspberry-pi-5)'s.

The facts are three clean-room records, cited by section:
[research-rp1.md](research-rp1.md) (the function, its interrupts,
Ethernet and USB), [research-rp1-clocks.md](research-rp1-clocks.md)
(clocks, pins and resets) and
[research-bcm2712-pcie-mip.md](research-bcm2712-pcie-mip.md) (the bridge
and the MSI receiver). No GPL source was read for this design.

## What is matched

The behaviour matched is what a Raspberry Pi 5 user sees under Linux:
the Ethernet port and the four USB ports work, and no interrupt is lost.
The structure is designed afresh.

* **RP1 as a function.** Identity `1de4:0001`, chip id `0x20001927`
  (revision C0) at BAR 1 offset 0; BAR 1 holds the peripherals and BAR 2
  64 KiB of SRAM ([F3](research-rp1.md#f3-rp1-as-a-pcie-function)).
  Linux treats it as one device with child devices at BAR 1 offsets and
  one interrupt domain of 61 vectors over the function's MSI-X entries,
  vector *n* being table entry *n* and configuration register
  `MSIX_CFG_n`
  ([vector map](research-rp1.md#vector-map-hardware-interrupt-numbers--msi-x-vector-indices)).
* **The acknowledge protocol.** A level-triggered peripheral's vector has
  `IACK_EN` set: RP1 masks the source when the message goes out and
  re-arms it when software writes `IACK`, sending again if the source is
  still high. An edge vector has `IACK_EN` clear and sends one message per
  rising edge. RP1's documentation warns that a level interrupt without
  the acknowledge can be lost; only the USB hosts' vectors are true edges
  ([the acknowledge protocol](research-rp1.md#the-acknowledge-protocol-as-linux-runs-it)).
* **Ethernet.** A Cadence GEM_GXL (revision 1p09), RGMII only, with a PHY
  at MDIO address 1 in `rgmii-id` mode, energy-efficient Ethernet broken
  at 1000BASE-T and 100BASE-TX, and a reset on RP1 GPIO 32, active low
  for 5 ms ([F4](research-rp1.md#f4-rp1-ethernet)). FreeBSD's `if_cgem.c`
  (BSD-2-Clause, release 15.1.0, SHA-256 `d50af315...`, and
  `if_cgem_hw.h`, `4b1d1973...`) is the behaviour reference; RP1 adds the
  writes Linux makes for it: the RGMII bit of `USRIO`, 64-bit addressing
  and descriptors, burst length 16 and the AXI pipeline limits.
* **USB.** Two Synopsys DWC3 (v3.30b) xHCI hosts, host-only, at BAR 1
  offsets `0x200000` and `0x300000`, 1 MiB each, on vectors 31 and 36,
  both edge ([F5](research-rp1.md#f5-rp1-usb)). FreeBSD's `dwc3.c`
  (release 15.1.0, SHA-256 `909eff6c...`) resets the core and both PHYs,
  sets host mode and host-in auto retry, applies its quirk defaults, and
  then runs its generic xHCI driver (`dwc3.c:232-267`, `:270-287`,
  `:318-362`, call order `:497-499`).

What no source gives, which the board probes of
[the plan's stage 1b-J](plan.md#1b-j-the-raspberry-pi-5-on-fiasco)
settle: the sizes of RP1's BARs and the place of its MSI-X table, whether
the firmware leaves RP1's clocks running and at which rates (Linux sets
the system PLL's VCO to 1 GHz, RP1's documentation says 2 GHz), any
per-block reset of the GEM or the USB hosts (Linux
resets the whole chip through a firmware call), what the USB hosts need
of `usbhostN_cfg` or their clocks, the PHY reset line's level at entry,
whether RP1's writes through `pcie2` are coherent with the CPUs' caches,
and the Ethernet address the firmware gives
([research-rp1-clocks.md](research-rp1-clocks.md#8-summary-and-open-items)).

## What the code does today

Nothing of RP1 exists. There is no platform record for the Pi 5, no
`rp1` or `cgem` peripheral, and no manifest row that names a block inside
a function's BAR. The device NIF writes a function's MSI-X entry 0 and
masks every other ([design-runtime.md](design-runtime.md#the-device-nif));
the PCIe design gives each function one message
([design-pcie.md](design-pcie.md#the-choice)). The network domain's
media are its own devices' transports and the `ether` interface, through
which a domain that drives a medium lends it
([design-wifi.md](design-wifi.md#the-ether-interface-and-wlan0)). The
xHCI controller process already runs a controller that is not a PCIe
function: it sends `open` and `master` only when its record names a PCIe
place ([design-usb.md](design-usb.md#the-controller-process)). The
Raspberry Pi 4's Ethernet PHY core, `erx_phy_c22`, drives a Broadcom
PHY, as the Pi 5's is by its tree's `brcm,` properties; the model is
unverified.

## The construction: a function and its parts

RP1 is one PCIe function whose BAR 1 holds every peripheral at a fixed
offset. erXos names each peripheral a driver needs as a **part** of that
function: a device row that names its function's row, a BAR, a block of
RP1's address map, and at most one MSI-X table entry with its trigger.
The function and its parts are one unit, given whole to one configured
domain, `rp1`, in every build. The rest follows from that:

* **No second bus.** A part is a device row like any other. Its record
  is a given record whose window is an offset and size in the function's
  BAR window object, which is how every record inside a unit already
  names its registers
  ([pages inside a domain](design-shared-devices.md#pages-inside-a-domain)).
  Its driver opens it with `erx_device` and reaches only the registers its
  peripheral's generated table names.
* **No demultiplexer.** Each part's entry is a message of its own, so
  each part has its own IRQ object and its own line, and the MSI
  receiver and the interrupt controller tell the vectors apart. Nothing
  reads RP1's interrupt status to find out which part interrupted.
* **No shared register written twice.** The registers that serve several
  parts (the chip id, the clocks, the MSI-X configuration
  block and the USB hosts' DWC3 globals) are the function's record's,
  written only by the function's driver, `erx_rp1`, but for the
  acknowledge the NIF makes for a level part ([Interrupts](#interrupts));
  a part's driver that
  needs one changed asks `erx_rp1` by message, as the unit rule has it.
  The pin registers are parts of their own, written only by the unit's
  pin driver ([Pins](#pins)).
* **One reset boundary.** RP1 has no per-block reset that any source
  gives, so the unit is the smallest thing that restarts as a whole, and
  the function is never reset: its link and BARs are the bootloader's
  ([design-pcie.md](design-pcie.md#the-bridge-seam)).
* **Mastering follows every part's reset.** The function masters only
  once each part's driver has reset its device, the order a single
  function's driver keeps between `open` and `master`, with the parts'
  drivers asking `erx_rp1` where a single driver asks the PCIe domain
  ([Mastering](#mastering)).
* **Isolation by the manifest's existing rules.** RP1 masters DMA with no
  IOMMU between it and memory, and its unit carries a network controller
  and USB hosts, so its holder holds that unit and nothing else and runs
  no file system and no network stack (property 9 of
  [design-system.md](design-system.md#the-manifest)). The `rp1` domain is
  therefore the USB domain of both hosts, and it lends Ethernet to the
  network domain through `ether`. Its release script, `rp1`, holds the
  base every domain boots, `erx_usb` and `erx_rp1`, the application of
  this design's drivers.

### The parts

The platform record, `config/platforms/raspi5.json`, lists RP1's parts
under the function's identity. Each part names a block of RP1's address
map, the MSI-X entry of its interrupt and that entry's trigger:

| Part | Peripheral | Block, BAR 1 offset and size | Entry | Trigger | Record role |
| --- | --- | --- | --- | --- | --- |
| `eth` | `cgem` | `eth`, `0x100000`, `0x4000` | 6 | level | `ordinary` |
| `usb0` | `xhci` | `usbhost0_xhci`, `0x200000`, `0xc100` | 31 | edge | `usb` |
| `usb1` | `xhci` | `usbhost1_xhci`, `0x300000`, `0xc100` | 36 | edge | `usb` |

The offsets and sizes are not written in the platform record: RP1's
address map is `hw/svd/rp1/rp1.svd`, from RP1's documentation
([BAR layout](research-rp1.md#bar-layout)), and the record names each
part's block by name, so the generator derives the offset and size. A
host's 1 MiB window holds its xHCI registers and, from `0xc100`, its
DWC3 globals ([F5](research-rp1.md#the-controllers)); the SVD gives the
xHCI registers a block of their own that ends where the globals begin,
so a USB part's window holds no DWC3 register
([The USB hosts](#the-usb-hosts)). The
entries are Linux's vector header and the triggers the Pi 5 tree's
([vector map](research-rp1.md#vector-map-hardware-interrupt-numbers--msi-x-vector-indices)).
RP1's UARTs, I2C, SPI and the rest are not listed: nothing needs them
yet, and each joins the table with the driver that does. The pin
blocks that the board's pin table names rows in are parts too, with no
entry, held by the unit's pin driver ([Pins](#pins)). Because the
parts are RP1's facts and come from the platform record and RP1's address
map, they do not depend on which device tree the board boots
([design-platforms.md](design-platforms.md#the-pi-5s-device-tree-and-its-license)).

**Part rows.** A manifest that places RP1's function on a domain gets
every part the platform record lists for it: the packer writes a row for
each, selector `part`, after the function's row, naming the function's
row as its `parent`, the BAR, the block's offset and size in `base` and
`size`, the entry (`mf_none` for none) and the trigger, with the role and
peripheral from the kinds table. A part cannot be placed apart from its
function, since no manifest names one: the unit rule holds by
construction ([Units](design-system.md#devices)). The packer refuses a
platform record whose parts name one entry twice, or name more entries
than `abi/erx_abi.txt`'s `msi_max`, so every part's message is its own.

**What the boot checks.** The function's BARs are reported by the PCIe
domain, so when the function's layout arrives the device service checks
each part against it: the part's BAR is a placed memory BAR, the part's
block lies within the BAR's span, and its entry lies below the
function's MSI-X table size. A part that fails gives the whole unit to no
domain, with a diagnostic naming the part and the BAR, as for any unit
the machine splits differently from the manifest
([design-system.md](design-system.md#devices)): the board then runs
without RP1's Ethernet and USB, and boots.

**The give.** The unit's give makes the window object over each placed
BAR's span, the function's record over BAR 1 whole, and for each part
its record at its block's offset in BAR 1's object, carrying its entry
and trigger, an `ERX_IRQ_MSI` object for its entry, whose message the
give writes into the part's record, and the contiguous memory its
peripheral's kind asks for. The function's route is `msix`, its
assigned messages the parts' entries
([design-pcie.md](design-pcie.md#the-choice)).

### The function's record and `erx_rp1`

The function's record covers BAR 1 whole, and its peripheral, `rp1`,
names only the registers its driver writes, each from
[research-rp1.md](research-rp1.md) or
[research-rp1-clocks.md](research-rp1-clocks.md):

| Block | Registers |
| --- | --- |
| `sysinfo` (`0x0`) | `CHIP_ID` |
| `clocks_main` (`0x18000`) | the system PLL's `CS`, `PWR`, `FBDIV_INT`, `FBDIV_FRAC`, `PRIM` and `SEC`; the `CTRL`, `DIV_INT` and `SEL` of `clk_sys`, `clk_eth` and `clk_eth_tsu` |
| `pcie_apbs` (`0x108000`) | `MSIX_CFG_0` to `MSIX_CFG_63`, with the set alias at `+0x800` and the clear alias at `+0xc00` |
| `usbhost0`, `usbhost1` (`0xc100` in each) | the DWC3 globals `GCTL`, `GUCTL`, `GUSB2PHYCFG0`, `GUSB3PIPECTL0` |

The parts' registers lie inside that window and outside every name the
`rp1` table has, so the function's driver cannot reach the GEM's or a
host's operational registers, or a pin's, by a wrong name
([confinement by name](design-shared-devices.md#pages-inside-a-domain)).
The DWC3 globals lie outside each USB part's window
([The parts](#the-parts)).

`erx_rp1` is an Erlang process over a pure core, `erx_rp1_core`, which
takes register readings and returns the next writes. Its start:

1. Open the function's record and send `open` for its place through the
   domain's `pci` facet: the function decodes and masters nothing.
2. Read `CHIP_ID`. Any value but `0x20001927` ends the start with
   `{error, {chip, Id}}`: the facts describe revision C0 alone.
3. The hosts: the DWC3 step on each host a part names
   ([The USB hosts](#the-usb-hosts)), and on every other host `GCTL`'s
   core soft reset set and left set, so a host no part names stays
   stopped.
4. Clocks, read first ([below](#clocks-read-first)).
5. The MSI-X configuration: clear `ENABLE` of every vector no part names,
   through the clear alias, so a peripheral the firmware left enabled
   raises nothing; for each part's entry set or clear `IACK_EN` by its
   trigger, then set `ENABLE`, each through an alias, so no write is a
   read-modify-write.
6. The NIF writes the function's MSI-X table from its assigned messages
   ([design-pcie.md](design-pcie.md#the-choice)).
7. Answer the unit supervisor, which starts the pin driver
   ([Pins](#pins)) and then the parts' drivers.

### Mastering

Each part's driver resets its device and then calls
`erx_rp1:master(Part)`, as a single function's driver sends `master`
after its reset. `erx_rp1` sends the function's `master` once every part
the platform record lists for the unit has called, and answers each call
then; a call after that is answered at once. The GEM's driver calls
after its reset's first step ([The driver](#the-driver)), and a host's
controller process after its controller's reset, where a PCIe
function's controller sends `master` ([The USB hosts](#the-usb-hosts)).

So the function masters only after every device a part names has
forgotten what the bootloader aimed it at, and DMA the bootloader left
running in the GEM or a host stays stopped until then, as the PCIe
domain's first start stopped it (rule 3 of
[design-platforms.md](design-platforms.md#dma)). A host no part names
stays in the reset of step 3.

A part's driver that restarts later finds the function mastering. Its
device has been aimed only at the part's own memory since the first
reset, memory that is the device's for the boot
([What a device keeps](design-system.md#devices)), so what the device
does before the new driver's reset lands there alone, and the driver
reads none of it before its install. A restart of `erx_rp1` sends `open`
first, which turns mastering off, so the unit starts again as at boot.

RP1's other bus masters, its DMA controller and the blocks no part
names, are masters erXos never drives
([design-platforms.md](design-platforms.md#dma)): raising the function's
mastering lets any that the bootloader left running go on, the residual
that section records. No source read says whether the bootloader starts
any of them; the board probe reads whether the GEM and the hosts run at
entry.

**Supervision.** The holder's unit supervisor
([design-system.md](design-system.md#the-holders-driver-control-facet))
is `rest_for_one`: `erx_rp1` first, then a `one_for_one` supervisor of
the parts' drivers, the GEM's lender and one USB tree per host. The end
of a part's driver restarts that driver alone, and the function stays
mastering. The end of `erx_rp1` ends every part's driver and starts the
unit again from step 1. A part's driver that keeps failing before its
call ends its supervisor within that supervisor's intensity, and with it
the unit. The unit supervisor's own end ends the domain,
whose restart the domain service runs within the row's intensity; the
holder's end sets the function `off`.

### Interrupts

Each part's entry is its own message, its own IRQ object and its own
line, bound and acknowledged by that part's driver as any direct line
([lines inside a domain](design-shared-devices.md#lines-inside-a-domain)).
The one thing RP1 adds is the acknowledge of a level vector.

**The vector's acknowledge.** RP1's protocol has the acknowledge after
the peripheral's service, which is exactly where every driver already
acknowledges its line. So for a part whose entry is level, the line's
acknowledge has two steps, which the NIF makes in this order: `IACK` of
the entry's `MSIX_CFG`, written through its set alias in the function's
record at the place the `rp1` peripheral's generated table gives, then
the IRQ object's acknowledge. The NIF derives the write from the part's
entry and trigger, which its record carries from its row and the boot
checked against the function's table; no driver passes an offset or a
bit, and no record carries one. An edge entry's acknowledge is the IRQ
object's alone.

* The NIF makes that one acknowledge wherever it acknowledges a line: at
  each `irq_ack/2`, and at the acknowledgement `irq_bind/2` makes so that
  a line a former driver left masked is unmasked for the new one
  ([design-runtime.md](design-runtime.md#the-device-nif)). A driver
  that ends between a delivery and its acknowledge leaves its vector
  masked in RP1 only until its successor binds the line: the bind's
  acknowledge re-arms it, and RP1 sends again if the source is still
  high.
* A driver on a level vector runs its code unchanged: the GEM driver, or
  a PL011 driver on one of RP1's UARTs once a part names one, acknowledges
  as it does on any line.
* The write cannot disturb another vector or `erx_rp1`'s setup: it is a
  set-alias write of one self-clearing bit in a register that serves only
  that vector, and `erx_rp1`'s writes to `ENABLE` and `IACK_EN` go
  through the same aliases.
* If the source is still high at the acknowledge, RP1 sends again, the
  edge reaches the IRQ object, and the driver is told again, so a level
  interrupt raised during the service is not lost.

On Fiasco the root binds each line of the MSI receiver as an edge line
([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)), whose
acknowledge comes after the `IACK` write.

### Clocks, read first

Linux resets RP1 through a firmware call and then programs its clocks
from the reset state
([section 7](research-rp1-clocks.md#7-resets-not-found)). erXos cannot
reset RP1, since only the kernel reaches the firmware's mailbox
(PL2 of [design-platforms.md](design-platforms.md#invariants)),
so `erx_rp1` reads what the firmware left, derives each clock's rate
from those readings alone, keeps a clock whose rate serves its consumer,
and programs only a clock whose new source and rate the readings settle.
It never programs the system PLL, whose power bits' polarity no source
settles and which `clk_sys`, the clock of RP1's fabric, may run from.
Its core is a pure function of the readings, tested over every
combination.

**Rates** ([sections 2 and 3](research-rp1-clocks.md#2-the-clock-tree-rp1-gives-ethernet-and-usb-found)).
The system PLL's VCO is the 50 MHz crystal times `FBDIV_INT` plus
`FBDIV_FRAC` as a 24-bit fraction, over `CS`'s `REFDIV`, and has a rate
only while `CS`'s `LOCK` (bit 31) is set; `pll_sys` is the VCO over
`PRIM`'s `DIV1` times `DIV2`, and `pll_sys_sec` the VCO over `SEC`'s
divider. A clock enabled by `CTRL`'s `ENABLE` (bit 11) runs at its
selected source over its `DIV_INT`, 0 meaning 2^16, and `SEL` reading 0
means its source is not running. A source the core does not follow, the
audio and video PLLs or a GPIO clock input, gives no rate.

| Clock | Decision |
| --- | --- |
| `clk_sys` | never written: Linux marks it always enabled in hardware. Without a rate the start ends with `{error, clk_sys}`; its rate goes to the GEM's driver for the MDC divider |
| `clk_eth` at 125 MHz, the RGMII transmit clock | keep it |
| `clk_eth` otherwise | the first of `pll_sys_sec` and `pll_sys` whose rate is 125 MHz times a divider from 1 to 255, its 8-bit range: write that divider, select that source, enable, the order in which Linux sets a rate; neither gives one: `{error, clk_eth}` |
| `clk_eth_tsu` enabled | keep it: erXos uses no timestamps |
| `clk_eth_tsu` off | select the crystal, divider 1, enable: 50 MHz, Linux's assignment |
| the USB hosts' clocks | untouched: no source says what the hosts need of them, and Linux gives the hosts none |

A start that ends with an error writes no clock; the unit
supervisor restarts it within its intensity, and then the domain ends
and the board runs without RP1, with the reading logged.

### Pins

RP1's pin controller is its IO-bank and pad blocks. They are set by the
pin driver of [design-pinctrl.md](design-pinctrl.md#the-pin-driver),
`erx_pins`, from the Raspberry Pi 5's pin table, and by nothing else:
`erx_rp1`'s register table names no pin register. The platform record
lists as parts, with no entry and the role of a pin controller's
device, `gpio`
([design-header-io.md](design-header-io.md#placement-units-and-domains)),
the blocks its rows need: `io_bank1` (`0xd4000`) and `pads_bank1` (`0xf4000`) for GPIO 32,
and `io_bank2` (`0xd8000`) for GPIO 42 and 43. The header's bank joins
them with the first driver of a header pin. The unit supervisor starts
`erx_pins` after `erx_rp1` answers and before the parts' drivers, so
every part finds its pins in their `default` state.

The table's rows on RP1, of kind `rp1`:

| GPIO | Owner | `default` | Other states |
| --- | --- | --- | --- |
| 32 | `eth` | `out`, level 1 | `reset`: level 0 |
| 42, 43 | `usb0` | `vbus1` | |

GPIO 32 is the PHY's reset (`ETH_RST_N`), active low. The `rp1` kind
realizes `out` through IO bank 1's own overrides, which RP1's
documentation gives: `FUNCSEL` 5 (GPIO), output enable forced on
(`OEOVER` 3) and the level forced by `OUTOVER` (2 low, 3 high), with the
pad's output-disable bit clear
([section 6](research-rp1-clocks.md#6-pads-function-select-and-the-gpio-setup-found--not-found)).
Linux drives the level through RP1's RIO block instead, whose base the
record does not give. The GEM's driver resets the PHY by selecting
`reset`, waiting 5 ms and selecting `default`, the tree's duration with
Linux's post-delay of 0; a driver that ends in between leaves the PHY
out of reset, since a state lasts only while its selector lives. At the
pin driver's start a PHY the firmware left in reset is released, and
one already out of reset sees no write.

GPIO 42 and 43 carry the USB ports' power enable and over-current input
in function `vbus1` (`FUNCSEL` 2), which the Raspberry Pi firmware's
tree gives `usb0` as its default state; which host drives which pin is
not known, and the rows give no pull, so the pads stay as found.

## The Ethernet controller

### Where it runs and where its frames go

The GEM is a part of RP1's unit, so the `rp1` domain drives it. Its
driver lends the medium to the network domain through `ether`, as the
WiFi domain lends `wlan0`
([design-wifi.md](design-wifi.md#the-ether-interface-and-wlan0)): the
network domain serves a service row `cgem0`, FreeBSD's name for the
driver's first unit, granted to the `rp1` domain, and runs
`erx_net_driver` over `erx_net_ether`, with `cgem0`'s addressing in its
configuration. The GEM's row is `ordinary`, not `network`: the network
domain alone holds a network device (property 8), and a lent medium is
not one, as the WiFi chip is not.

Each frame crosses between the two domains as a message within the
credit `ether` grants. That cost is on the watch list
([todo-performance.md](todo-performance.md)), measured on the board
against the line rate.

### The driver

`erx_cgem` is an Erlang process over the GEM part's record. Its
decisions are pure cores: `erx_cgem_core`, the reset and configuration
as a state machine over register readings; `erx_cgem_mdio`, the GEM's
PHY maintenance register as clause 22 commands and polls, the twin of
the Raspberry Pi 4's `erx_mdio` for another register; the GEM ring form
below; and `erx_phy_c22`, reused unchanged, which the network
application and the `rp1` application both take from a library
application. Register facts are FreeBSD's `if_cgem_hw.h` and the facts
record's.

**Reset and configuration**, in FreeBSD's order (`cgem_reset`,
`if_cgem.c:1032-1067`), with RP1's writes:

1. `NET_CTRL` 0, which stops transmit and receive; `NET_CFG` with the
   data bus width that `DESIGN_CFG1` reports; statistics cleared;
   `TX_STAT` and `RX_STAT` cleared; every interrupt disabled; the hash
   filter 0; both queue base addresses 0. Then the driver binds its line
   and calls `erx_rp1:master/1` ([Mastering](#mastering)); what follows
   runs with the function mastering.
2. The MDC divider: the smallest of `NET_CFG`'s dividers that keeps MDC
   at or below 2.5 MHz from `clk_sys`'s rate, which `erx_rp1` reports: 96
   at 200 MHz. The 2.5 MHz limit is clause 22's, unverified against
   IEEE 802.3 here. Then `NET_CTRL` with the management port enabled.
3. The PHY: its reset through the pin driver ([Pins](#pins)), then
   `erx_phy_c22` at MDIO address 1.
   Energy-efficient Ethernet is not advertised, as the tree's
   `eee-broken-1000t` and `eee-broken-100tx` ask: the driver clears the
   PHY's EEE advertisement (MMD 7, register 60) through clause 22's MMD
   access registers 13 and 14, register numbers unverified against IEEE
   802.3 here. The PHY has no interrupt line, so the driver reads its
   status once a second, as FreeBSD's `cgem_tick` does
   (`if_cgem.c:940-971`).
4. `USRIO` (`0x0c0`) bit 0, RGMII. The wrapper's `eth_cfg` is not
   written: its transmit clock generator follows the speed the MAC
   reports, and Linux writes none of it
   ([what Linux writes](research-rp1.md#what-linux-writes-for-rp1s-ethernet)).
5. `DMA_CFG`: the receive buffer size, burst length 16, and 64-bit
   addressing (bit 30) when `DCFG6` (`0x294`) bit 23 reads set; with the
   bit clear the driver refuses with `{error, dma_width}`. RP1 maps a
   32-bit master's addresses onto the first 4 GiB of RAM
   ([BAR layout](research-rp1.md#bar-layout)), so 32-bit descriptors
   could name buffers there; the driver uses the 64-bit form alone, the
   one Linux uses for RP1, so the ring form has one descriptor layout and
   the part's memory may lie anywhere in RAM.
6. `AMP` (`0x054`): 8 outstanding reads, 8 outstanding writes, and the
   write limit counted from AW to B, Linux's values for RP1. An AXI burst
   over 16 beats is fatal to the GEM until a reset no source gives, which
   is why the burst length is 16.
7. Priority queues past the first, as many as `DCFG6` reports, are
   pointed at a one-descriptor receive ring and a one-descriptor
   transmit ring that the CPU owns, as FreeBSD's `cgem_null_qs` does
   (`if_cgem.c:376-403`).
8. The Ethernet address into specific address 1. The address is the
   `local-mac-address` of the boot tree's node that the `ethernet0` alias
   names, which the device service reads at boot into the part's record,
   as a GENET record carries its node's; else the one the firmware left
   in specific address 1; else a random locally administered unicast
   address, FreeBSD's order
   ([design-network-stack.md](design-network-stack.md#the-driver)).
   Whether the firmware writes the property on the Pi 5 is a board probe.
9. `negotiate/2`, the form's install, then interrupts enabled for receive
   complete, transmit complete and the bus error bits, then `NET_CTRL`
   with transmit and receive enabled.

On the PHY's link report the driver writes `NET_CFG`'s speed and duplex
bits and sends `{erx_ether, Ref, link, up | down}`. A frame from the
network domain is posted within the credit the driver granted; a
received frame goes out within the credit the network domain granted,
and the driver returns credit as frames leave for the controller.

**Interrupts.** Entry 6 is a level vector, so the line's acknowledge
carries RP1's ([Interrupts](#interrupts)). On a delivery the driver reads and clears
the GEM's interrupt status, completes both queues, and acknowledges.

### The GEM ring form

A fifth descriptor form beside those of
[design-device-dma.md](design-device-dma.md#the-descriptor-forms),
keeping that design's rules. The GEM's descriptors in 64-bit mode are
four words, 16 bytes: address low, control, address high, unused
(`if_cgem_hw.h:378-441`). The controller writes status back into the
descriptors the CPU wrote, so a ring is written by both sides, which
the one-writer rule allows only by handing it over in granules. Three
things make the handover safe on any bus. The word that hands a
descriptor over carries everything the CPU changes in it, so a handover
is one store. The CPU never stores into a word the controller writes
back. And the CPU stores a group's handover words in reverse ring
order, the group's first descriptor last: a dirty line can reach memory
by eviction before the clean, but the controller takes descriptors in
ring order and stops at the first it does not own, so it takes none of
a group before the last store, after which the CPU stores nothing into
the group.

* **Groups.** Each ring is a sequence of **groups**, each one granule
  `G` of `G / 16` descriptors, 4 where `G` is 64 bytes. A group is a
  region whose writer moves as a buffer's does: the device's from its
  handover until every descriptor in it that the CPU handed has
  reported done, and the CPU's otherwise. The common design's handing
  over, taking back and three barriers apply to it as to a buffer
  ([The three rules](design-device-dma.md#the-construction-handoffs-of-granules)),
  and while the device holds it the CPU stores nothing into it and only
  observes it, by acquisition, as it observes a used ring. Each ring's
  size is a whole number of groups. Each pool buffer is a region of its
  own, as in every form.
* **A standing table.** Buffer *i* is descriptor *i*'s for the life of
  the queue, so install writes each descriptor's address once, with the
  wrap bit on the last (word 0 bit 1 for receive, control bit 30 for
  transmit).
* **Receive.** Install hands every group with each descriptor's `OWN`
  (word 0 bit 0) clear and writes the ring's device address to
  `RX_QBAR` and `RX_QBAR_HI` (`0x4d4`). A descriptor's handover is one
  store of its word 0, which holds its address's low word, the wrap bit
  and `OWN` clear; the control word is the controller's alone, written
  with a frame's status when it sets `OWN`, and the CPU never writes it.
  `complete/2` acquires in the common design's two phases
  ([A report is a snapshot](design-device-dma.md#releases)): first each
  handed descriptor's word 0 from the ledger's position, stopping at the
  first whose `OWN` reads clear, then the report barrier; then, with the
  lines those descriptors lie in cleaned and invalidated again and the
  completion barrier passed, those descriptors whole. A descriptor so
  acquired reports a frame of the length in control bits 12 to 0, at
  most the buffer, with start and end of frame (bits 14 and 15) and bad
  FCS (bit 13). Its buffer is taken back and copied at once, so no frame
  waits for its group. When every descriptor of a group has reported,
  the group is the CPU's again: the sequencer stores each descriptor's
  word 0 with `OWN` clear, the group's first descriptor last, cleans the
  group and hands it back. A descriptor the controller reads before its
  store lands reads `OWN` set and is not taken, and is read again for a
  later frame. The driver drops a frame without both start
  and end of frame, or with bad FCS, since every frame fits one buffer.
* **Transmit.** Install writes every descriptor with `USED` (control
  bit 31) set, all the CPU's, and the ring's device address to `TX_QBAR`
  and `TX_QBAR_HI` (`0x4c8`). `post_frame/5` copies the frame into the
  buffer at the ledger's next position and describes its control word:
  the length, last buffer (bit 15), the wrap bit where it stands, `USED`
  clear, one store that hands the descriptor over. The sequencer stores
  the control words of each group's new posts, the first in ring order
  last, cleans and hands the groups, then writes `NET_CTRL` with start
  transmit (bit 9). A transmit report is that same word, `USED`
  and the AXI error bit 27 together, so one load of it is the report's
  snapshot. The controller sets `USED` in a frame's descriptor
  when it has sent it and stops at the first descriptor it finds with
  `USED` set. A post that falls in a group still handed waits in the
  driver until that group comes back, every frame in it sent; the
  controller is then stopped at the first descriptor of the group that
  the CPU had not posted, and the next start resumes there. That the
  controller resumes at the descriptor it stopped at, not at
  `TX_QBAR`, is what FreeBSD's continuous transmit ring assumes; the
  board pass confirms it.
* **Reset.** `negotiate/2` writes `NET_CTRL` 0, FreeBSD's stop
  (`cgem_stop`, `if_cgem.c:1174-1230`), which waits for nothing. The
  form's idle report is `TX_STAT`'s go bit (bit 3) clear; no source read
  gives a receive-idle report, so whether a frame being written when
  receive is disabled can land after the reset is a board-pass item, and
  the form is not enabled on a board before the pass settles it.
* **Errors.** A bus error (`TX_STAT` or `RX_STAT` bit `HRESP_NOT_OK`, or a
  transmit descriptor's AXI error bit 27), an index past a ring or a
  length past a buffer breaks the queue, as a malformed used entry does
  in every form; the driver ends, and its restart resets the GEM.

On a coherent bus the cleans and invalidates are empty and the groups
still hold; whether `pcie2` is coherent is a board probe, and the form
is correct either way.

Two premises of the form rest on no source read, since the GEM's own
manual was not read: that the controller stores a receive descriptor's
`OWN` after its status, which the second phase relies on as it relies
on an xHCI event's cycle bit; and that receive takes a descriptor it
once found not free when a later frame arrives. The board pass checks
both under a stress of short frames
([plan](plan.md#1b-j-the-raspberry-pi-5-on-fiasco)), and the form is
not enabled on a board before it has.

## The USB hosts

The two hosts are `usb` parts, so each is a controller of the USB stack
that is not a PCIe function: its record names no place, and the xHCI
controller process sends no `open`, and sends its `master` to
`erx_rp1:master/1` rather than through `pci`
([design-usb.md](design-usb.md#the-controller-process)). Its window is
its xHCI registers, the host's first `0xc100` bytes, which end where the
DWC3 globals begin; the controller process places its runtime
registers, doorbells and extended capabilities from `RTSOFF`, `DBOFF`
and the capability pointers the controller reports, and the NIF refuses
any access past the window, so a malformed offset cannot reach a DWC3
register. Its interrupt is its own entry, edge, and its DMA memory is
the part's. The `rp1` domain
runs one `erx_usb_sup` tree per host, as a USB domain does per
controller, so each host has its own drives and its own input tree, each
named by its own part's row ([design-usb.md](design-usb.md#who-holds-a-controller)).

**The DWC3 step.** In its start, before any part's driver runs,
`erx_rp1` runs FreeBSD's DWC3 sequence on the globals of each host a
part names, as it applies on RP1's tree properties; the controller
process's own reset of the xHCI follows, before its `master/1`
([Mastering](#mastering)):

1. Set `GCTL`'s core soft reset, then `GUSB2PHYCFG0`'s and
   `GUSB3PIPECTL0`'s PHY soft resets; wait 1 ms; clear both PHY resets,
   then the core reset (`snps_dwc3_reset`, `dwc3.c:232-267`). RP1's hosts
   are host-only, so the dual-role suspend bits are not touched.
2. `GCTL`'s port capability direction to host, and `GUCTL`'s host-in
   auto retry (`snps_dwc3_configure_host`, `:270-287`).
3. In `GUSB2PHYCFG0`, the USB 2 free clock and the low-power mode enable
   set, FreeBSD's defaults where the tree gives no property against them;
   in `GUSB3PIPECTL0`, receiver detection in P3 disabled (bit 28), which
   RP1's tree asks for and FreeBSD implements (`snps_dwc3_do_quirks`,
   `:318-362`).

Linux also writes the AXI pipelined transfer limit, the enhanced
full-speed NAK, three park-mode disables and the transmit threshold for
RP1 ([DWC3 properties](research-rp1.md#dwc3-properties-rp1dtsi-sets-both-controllers-identically)).
FreeBSD writes none of them, and no source says which failure each
prevents, so erXos writes none until a board test shows the failure it
prevents; each then joins the step with that test
([Open decisions](#open-decisions)). `usbhostN_cfg` is not written: its
registers are documented nowhere read, and Linux writes none. The chip
id check of `erx_rp1`'s start stands for the hosts' identity: revision
C0's hosts are DWC3 v3.30b ([F5](research-rp1.md#the-controllers)).

## Concurrency

Everything of the unit runs in one runtime, so the only concurrency is
between processes and between the CPU and RP1's devices.

* `erx_rp1` alone writes the function's registers, but for the NIF's
  `IACK` writes. Part drivers reach them only by message (`master/1`),
  answered in order. `erx_pins` alone writes the pin registers, and a
  part's driver changes its pins only by selecting a state
  ([Pins](#pins)).
* The NIF's `IACK` writes and `erx_rp1`'s vector setup write the same
  registers only through the set and clear aliases, each write touching
  only its own bits, so their order does not matter.
* The parts' drivers start after `erx_rp1` answers, so no part runs
  before its vector, its clocks and its host's DWC3 step are set, and
  the function masters
  only after every listed part's `master/1`, so no device of a part
  masters before its reset ([Mastering](#mastering)).
* Each part's driver and its device share memory only through its own
  form's ledger; the GEM ring form's groups keep one writer per granule
  at every moment.

## Failure behaviour

| Failure | What happens |
| --- | --- |
| `pcie2`'s link is down at entry, or RP1 is not at its place | the PCIe domain reports no function; the device service gives the unit to no domain; the board boots without Ethernet and USB, with the reason logged |
| a part does not fit the reported BAR, or its entry is past the table | the unit is given to no domain, the part and BAR named |
| an unknown chip id, `clk_sys` without a rate, a `clk_eth` that no followed source can make 125 MHz | `erx_rp1`'s start fails with the reason; after the unit's intensity the domain ends, and after the row's the board runs without RP1 |
| a part's driver that ends before its `master/1` | the function stays decoding; the driver's restart resets its device and calls again; past its supervisor's intensity the unit ends |
| a GEM bus error, a broken queue, a PHY that does not answer | `erx_cgem` ends; its restart resets the GEM; its `ether` link ends and a new offer starts it |
| a GEM whose AXI burst state persists after its reset | the restarted driver fails again; the unit's intensity ends the domain; the residual is RP1's missing block reset |
| an xHCI host fault | as [design-usb.md](design-usb.md#failure-handling) states for any controller; the other host and the GEM go on |
| the `rp1` domain ends | the device service sets the function `off`; the network domain's `cgem0` link ends as for any lender's end; the domain service restarts the domain |

Nothing here resets RP1: neither the PCIe design's bridge nor anything
else has a reset path for it.

## Refusals and error results

| Call or input | Result |
| --- | --- |
| `erx_rp1` start, chip id other than `0x20001927` | `{error, {chip, Id}}` |
| `erx_rp1` start, `clk_sys` without a rate, or a `clk_eth` that no followed source can make 125 MHz | `{error, clk_sys}`, `{error, clk_eth}` |
| a platform record whose parts name one entry twice, or more entries than `msi_max` | the packer fails the build, naming the parts |
| `erx_cgem` with `DCFG6` reporting 32-bit addressing | `{error, dma_width}` |
| a GEM ring index past the ring, a length past a buffer | the queue breaks, `{error, broken}` until `negotiate/2` |
| a part row in a manifest that does not place its function | impossible to write: the packer makes part rows only after their function's row |

## Verification

Each test names the seeded fault that proves it ran.

| Test | Passing case | Seeded failure |
| --- | --- | --- |
| `erx_rp1_core`'s clocks table, exhaustive over the readings | every reading gives the table's decision, with each rate derived from the dividers read; an enabled `clk_eth` at 100 MHz is moved to 125 MHz, an unlocked PLL gives its outputs no rate, and no reading produces a PLL write | a core that keeps any enabled `clk_eth` without deriving its rate; the 100 MHz case sees no write and fails |
| `erx_rp1_core`'s vector setup | every unnamed vector is cleared, each part's `IACK_EN` follows its trigger, `ENABLE` comes last, every write is to an alias; a host no part names is left with its core soft reset set, and a named host gets the DWC3 step | a level entry given edge; the test sees `IACK_EN` clear for entry 6 |
| mastering, `erx_rp1` over a model function and model parts | `master` is sent only after every listed part's `master/1`, each answered then; a later call is answered at once; a restart of `erx_rp1` sends `open` before anything else | a start that sends `master` when it answers the supervisor; the model GEM, left running on the loader's ring, writes memory while the function masters before its reset and the test fails |
| the vector's acknowledge, NIF | a level part's `irq_bind/2` and each `irq_ack/2` write `IACK` of its own entry's set alias before the IRQ object's acknowledge; an edge part's write none; a driver killed between a delivery and its acknowledge leaves a held-high source that its successor's bind delivers again | the bind's acknowledge made without `IACK`; the successor never receives the held-high source |
| part rows, packer | a manifest that places RP1 gets its three parts after the function's row, offsets from `rp1.svd`; a record naming entry 6 twice fails the build | a part dropped from the output; the unit test counts two parts |
| a USB part's window | an `RTSOFF` that places the runtime registers at `0xc100` makes the controller process's access refused as outside the window | the part's block given the host's whole 1 MiB; the access reaches the model's `GCTL` and the test fails |
| the boot's part check | a part past the BAR's span gives the unit to no domain with the diagnostic | a check that compares the offset alone; a part whose end crosses the span passes and the test fails |
| `erx_cgem_core`'s reset | the writes in FreeBSD's order with `USRIO`, `DMA_CFG` bit 30 and `AMP` | `DCFG6` reading 32-bit; the core must refuse, and a core that sets bit 30 anyway fails |
| the GEM ring form, host-built | receive and transmit over a model controller that may act between any two of the sequencer's stores, taking a handed descriptor and writing its status, `OWN` or `USED` and, for transmit, partly sent groups, behind a model cache that may write a dirty line back at any store; every completion the model writes is the one the driver reports, and no CPU store lands in a handed group | a sequencer that also stores a receive descriptor's control word after its word 0; the model, acting between the two stores, has its completion overwritten and the test sees the frame lost; a sequencer that stores a group's words in ring order: the model cache writes the first descriptor back early, the model takes it while the CPU still stores the second, and the clean overwrites its completion; and a sequencer that rewrites a receive descriptor before its group completes, which the model's writer check catches |
| `erx_cgem_mdio` | read and write words, polls to completion and the timeout | an off-by-one in the PHY address shift; the decode test fails |
| the GEM ring form's fuzz target | arbitrary descriptor words and lengths never produce a frame past its buffer | the length bound removed; the fuzzer finds an over-long frame |
| DWC3 step | the writes in FreeBSD's order, the PHY resets cleared before the core reset | the core reset cleared first; the order test fails |
| board pass: Ethernet | a DHCP lease and a TCP transfer on `cgem0`; a link pulled and replaced | the PHY reset skipped; on a board whose firmware left the PHY in reset, the link never comes up |
| board pass: USB | a keyboard on each host's ports types into the shell; a USB drive mounts | entry 31 left disabled; the first host's devices never enumerate |

The fuzz target for the GEM ring form lands with the form, as every
parser of device-written memory does.

## Alternatives considered

* **RP1 in the network domain in development builds.** It would put
  frames straight into the stack, but the network domain would then be
  the USB domain of both hosts too, and development and release builds
  would differ in shape. One `rp1` domain in every build keeps one
  arrangement; the cost of lending is measured, and this is revisited
  only if the measurement asks for it.
* **The parent acknowledges.** Part drivers could ask `erx_rp1` for each
  level acknowledge by message, as the unit rule allows for shared
  registers. That costs a message per interrupt and makes every driver
  on an RP1 level vector RP1-specific; the NIF's derived `IACK` costs
  one write, and drivers stay unchanged.
* **`erx_rp1` stops each engine before mastering.** `erx_rp1` could
  write the GEM's `NET_CTRL` and each host's `USBCMD` itself before
  `master`, with no call from the parts. The GEM's registers would
  then have two writers, against the unit's one-writer rule, and each
  part's reset would be split between two drivers; the call keeps each
  device's reset with its driver.
* **A line owner per level vector.** The shared-line owner could run the
  acknowledge at the end of each round. A level vector has one driver,
  so the owner would be a process with nothing to share.
* **RP1's own interrupt demultiplexing.** One MSI-X entry and a dispatch
  over `INTSTATL` and `INTSTATH` would need a demultiplexer process and
  a second kind of line; one entry per part needs neither.
* **Parts from the device tree.** RP1's tree lists the peripherals as
  child nodes, but its license is unsettled
  ([design-platforms.md](design-platforms.md#the-pi-5s-device-tree-and-its-license)), and the
  facts are the chip's, the same on every board; RP1's address map and
  the platform record carry them.
* **Descriptor rings in RP1's SRAM.** The GEM's rings could live in
  BAR 2's SRAM, which no CPU cache holds, removing the groups; no source
  says whether the GEM can address that SRAM or at what address.

## Open decisions

* **Linux's five further DWC3 settings for RP1.** Recommendation: write
  none until a board test shows the failure one prevents, then add that
  one with its test. The alternative is to copy Linux's values on the
  ground that RP1's vendor chose them; that writes registers no design
  explains.

## References

* [research-rp1.md](research-rp1.md), [research-rp1-clocks.md](research-rp1-clocks.md),
  [research-bcm2712-pcie-mip.md](research-bcm2712-pcie-mip.md): the facts.
* FreeBSD release 15.1.0: `sys/dev/cadence/if_cgem.c` (SHA-256
  `d50af315435d912c737ac30764e170053b24fb21fb50e847b4fa3ece416367ca`),
  `if_cgem_hw.h`
  (`4b1d19738e6507a47f4d87052e062cd8b8c518754495c99e595524b423778ea9`),
  `sys/dev/usb/controller/dwc3/dwc3.c` (SHA-256 beginning `909eff6c3cf2972e`),
  `dwc3.h` (beginning `52fe6e29fc345c52`), as recorded in
  [research-rp1.md](research-rp1.md#sources).
* [design-pcie.md](design-pcie.md), [design-shared-devices.md](design-shared-devices.md),
  [design-device-dma.md](design-device-dma.md), [design-usb.md](design-usb.md),
  [design-wifi.md](design-wifi.md), [design-system.md](design-system.md).
