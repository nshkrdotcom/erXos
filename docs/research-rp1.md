# RP1 on the Raspberry Pi 5: PCIe function, Ethernet and USB facts record (clean room)

A point-in-time research record, written on 2026-11-21 on the Apple Silicon
macOS development host whose scratch directory holds the sources listed
below. It answers facts F3, F4 and F5 of the Pi 5 plan: what the RP1
peripheral chip looks like to the host as a PCIe function, what its Ethernet
wrapper around the Cadence GEM needs, and what its two DWC3 USB host
controllers need. It is written so that the authors of erXos's RP1 core,
Ethernet driver and USB driver never read the GPL-licensed sources.

This record states hardware facts and observed driver behavior in its own
words. It contains no code, no copied comments and no identifiers from Linux
except register, field, property and device-tree names, which are hardware
facts. Design and code agents read this record, never the Linux sources.

Citation form: `PDF:line` is the RP1 Peripherals PDF's text extraction
(`rp1.txt`, line numbers of that file). `RPI:file:line` is the Raspberry Pi
downstream Linux tree at the pinned commit; short names used below:
`rp1.c` = drivers/mfd/rp1.c, `rp1.dtsi` and `rpi-5-b.dts` =
arch/arm64/boot/dts/broadcom/..., `macb.c` and `macb.h` =
drivers/net/ethernet/cadence/macb_main.c and macb.h, `dwc3-core.c`,
`dwc3-core.h`, `dwc3-host.c` = drivers/usb/dwc3/..., `clk-rp1.c` =
drivers/clk/clk-rp1.c, `rp1-int.h` = include/dt-bindings/mfd/rp1.h.
`FB:file:line` is FreeBSD. Statements marked **inference** are my reading of
a name or arithmetic on cited values. **Not found** means the sources read do
not state it; a board probe or another source must settle it.

## Sources

Fetched over HTTPS on 2026-11-21 (the PDF on 2026-11-16), outside the tree,
read as data, nothing run.

**RP1 Peripherals PDF** (Raspberry Pi), in
`~/erxos-scratch/sources/pi5/rp1/`:

| SHA-256 | file |
|---|---|
| 87fb7b24e8d9add075b849d095a107827610c0409ea194785af624c1ea986c3d | rp1-peripherals.pdf |
| 4861893b9ab3bd00e7692424baa5bdd1b876f6266a76346c9ba774d8ffca8d0f | rp1.txt (pdftotext of the PDF) |

**Raspberry Pi Linux, branch rpi-6.12.y, commit
`dcc3a57b713fe33c33a9eba7e0704bc87aed6698`** (head on 2026-11-21, resolved
with the GitHub API), from
`https://raw.githubusercontent.com/raspberrypi/linux/<commit>/<path>`, in
`~/erxos-scratch/sources/pi5-linux-rp1/` (flattened file names):

| SHA-256 | path |
|---|---|
| a968264abbbe463368b72e0087393d5ab3f0365b20738838d5be55c03d9bb658 | drivers/mfd/rp1.c |
| 8e454c1af9fd4e87e05d03ca2de029c217917a6e1ae997e9d61c1bd63ba4e214 | include/dt-bindings/mfd/rp1.h |
| c8f863d2349b6a3cd4ffdc79e8bb7618d9bd92b4648177eb7a09e84e84cd573b | include/linux/rp1_platform.h |
| ab3fe239e9a62742d035187ec50f65ec769cff002788f0e12b2afcad0bbaf460 | arch/arm64/boot/dts/broadcom/rp1.dtsi |
| f27bea575be85d9e0bbef3a1337961f12143cd7487079ee33d92c2f2c4d45df6 | arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts |
| 874963e6586489a6cad16c148499dc93eb77de5f8ce26e37cda7e5e2f37dd7f7 | arch/arm64/boot/dts/broadcom/bcm2712-rpi.dtsi |
| c3d9a9d79e48b9517424a1c472f34fcd7e954da09a238935116f1358648d5082 | drivers/net/ethernet/cadence/macb_main.c |
| 250569eb78eee6d83025204237f94a4da76e8d6e65960852b6a7bacc041d5910 | drivers/net/ethernet/cadence/macb.h |
| 52e48eca35f0127e689798a0e24143f455bcc068ea285015b0c0775424a0a96e | drivers/clk/clk-rp1.c |
| c042460c45b1970502a54da6cf7aa2320729ad6491ad5122139908c8cbe93c8a | drivers/usb/dwc3/core.c |
| 60d12b97b04391a5c184bb01cba42729fdef2cc30a5856e3685c9da52a0acd55 | drivers/usb/dwc3/core.h |
| 5d74bfb78e09dc2e0fa1c0d4c38ab5e897af4d1ffaebb728c83d168a8480689f | drivers/usb/dwc3/host.c |

drivers/misc/rp1_pci.c does not exist at that commit (HTTP 404); the RP1 PCI
driver is `drivers/mfd/rp1.c`.

**FreeBSD, tag release/15.1.0**, tag object
`017261f1aac302491c7789bbd19c95e222d7faee`, commit
`96841ea08dcfa84b954a32dc5ae1a26c28966cf4` (BSD-2-Clause), from
`https://raw.githubusercontent.com/freebsd/freebsd-src/<commit>/<path>`, in
`~/erxos-scratch/sources/freebsd-15.1.0-rp1/`:

| SHA-256 | path |
|---|---|
| d50af315435d912c737ac30764e170053b24fb21fb50e847b4fa3ece416367ca | sys/dev/cadence/if_cgem.c |
| 4b1d19738e6507a47f4d87052e062cd8b8c518754495c99e595524b423778ea9 | sys/dev/cadence/if_cgem_hw.h |
| 909eff6c3cf2972ee91159ade5ed8e6c3ea14754e20549d33f99bb0c18ea7226 | sys/dev/usb/controller/dwc3/dwc3.c |
| 52fe6e29fc345c527aaf22ac566019426a3074b284e177a30dcf7d1cf5cb3be0 | sys/dev/usb/controller/dwc3/dwc3.h |

## F3: RP1 as a PCIe function

### Identity

- PCI vendor 0x1de4, device 0x0001, revision value 2 for the "C0" chip
  (`rp1.c:38-40`, `:359-362`). The driver matches on vendor and device only.
- Chip identity is read through BAR 1 at peripheral offset 0 (`sysinfo`,
  `rp1-int.h` RP1_SYSINFO_BASE = 0): register 0x00 is the chip id, register
  0x04 the platform word (`rp1.c:49-50`, `:304-305`). The C0 chip id is
  0x20001927 (B0 is 0x10001927); the platform word has bit 0 set for an FPGA
  and bit 1 for the real ASIC (`rp1_platform.h:12-16`). Linux refuses any chip
  id other than C0 (`rp1.c:308-311`).
- One PCIe function, one virtual channel, three 32-bit non-prefetchable BARs,
  an integrated MSI-X capability, and a Gen 2 x4 link (`PDF:4240-4254`).

### BAR layout

- BAR 1 is the peripheral space: the host reaches every peripheral at its
  offset from BAR 1's assigned base (`PDF:360-361`; `rp1.c:300` takes the
  base of BAR 1 as the peripheral base and adds the peripheral's offset
  everywhere).
- BAR 2 is the shared SRAM, 64 KiB, at offsets from BAR 2's base
  (`PDF:360-361`, `PDF:311` for the 64k size). Linux does not use it.
- BAR 0: its role is **not found** in the PDF or in `rp1.c`, which only prints
  BAR 0 and 1 (`rp1.c:265-266`). **Inference:** the PDF's PCIe endpoint section
  lists three BARs and names only BAR 1 and BAR 2 as host windows, so BAR 0 is
  probably a small control window; a board probe must read its size.
- BAR sizes are **not found**. Linux's only sanity rule: it declines to bind
  and complains that firmware is not running when BAR 1's resource is
  0x10000 bytes or smaller (`rp1.c:268-272`). So the firmware or the
  bootloader must have sized BAR 1 above 64 KiB before the OS sees it.
- Peripheral offsets inside BAR 1 (all 16 KiB blocks unless noted;
  `rp1-int.h` Address map, cross-checked with `PDF:3422ff` table 2 and
  `PDF:4212-4218`, `PDF:5656-5658`): sysinfo 0x000000, syscfg 0x008000,
  resets 0x014000, clocks (default bank) 0x018000, UART0..5 0x030000,
  0x034000, 0x038000, 0x03c000, 0x040000, 0x044000, io_bank0 0x0d0000, io_bank1
  0x0d4000, io_bank2 0x0d8000, pads_bank0..2 0x0f0000, 0x0f4000, 0x0f8000,
  pads_eth 0x0fc000, eth (GEM) 0x100000 (size 0x4000 in the device tree),
  eth_cfg 0x104000, pcie_apbs (the MSI-X configuration block) 0x108000,
  usbhost0_cfg 0x160000, usbhost1_cfg 0x164000, vbusctrl 0x170000, usbhost0
  0x200000 (1 MiB), usbhost1 0x300000 (1 MiB), eth bus window through
  exac 0x400000. Linux maps the outbound window as 0x410000 bytes starting at
  PCIe bus address 0 (`rpi-5-b.dts:134-141`), i.e. peripheral offset N is
  reached at PCIe bus address N within the RP1 window.
- Address translation the board tree describes for the host root complex
  (F1's subject, listed here because RP1's masters depend on it;
  `rpi-5-b.dts:134-160`): RP1's own 40-bit view of its peripherals is
  0xc0_40000000 (that is, 0xc040000000) onwards. Outbound, PCIe bus address
  0x0.. maps to RP1 0xc0_40000000.. for 0x410000 bytes. Inbound (RP1 DMA to
  host memory): RP1 addresses 0x10_00000000 and up map to PCIe bus addresses
  0x10_00000000 and up, for 64 GiB, with a second window that maps RP1
  addresses 0x0.. (32-bit masters) to PCIe 0x10_00000000 for 64 GiB; and a
  third that maps RP1's 0xc0_40000000.. (so its DMA can reach its own
  peripherals) to PCIe 0x0.. for 0x410000 bytes.

### The MSI-X block (`pcie_apbs`, PCIE_CFG registers)

The block sits at peripheral offset 0x108000 in BAR 1 (`rp1.c:326`,
`rp1-int.h` RP1_PCIE_APBS_BASE; `PDF:4284-4300`). Linux maps 0x1000 bytes of it.

| offset | register | meaning |
|---|---|---|
| 0x000 | DBI | address fields for DBI access |
| 0x004 | CONTROL | miscellaneous; bit 2 APP_LTSSM_ENABLE resets to 1 |
| 0x008 + 4*n | MSIX_CFG_n, n = 0..63 | per-vector configuration |
| 0x108 | INTSTATL | raw interrupt status, vectors 31:0, read only |
| 0x10c | INTSTATH | raw interrupt status, vectors 63:32, read only |

(`PDF:4284-4300`, `PDF:4430-4432`, `PDF:4551-4592`.) RP1 has 61 vectors
connected to sources, numbered 0..60, but the table has 64 (`PDF:5583`;
`rp1-int.h` RP1_INT_END = 61).

MSIX_CFG_n fields (`PDF:4605-4634`): bit 3 IACK_EN (enable the acknowledge
function, reset 0); bit 2 IACK (writing 1 clears the mask the block set when
it generated the interrupt; self-clearing); bit 1 TEST (ORed into the
interrupt source, for testing); bit 0 ENABLE (interrupt enable, reset 0);
bits 14:12 TC (PCIe traffic class); bits 18:16 FUNC (PCIe function); all
others reserved.

Atomic access: every APB block in the PDF's tables has an "Atomic Access"
column; `pcie_apbs` and the cfg blocks are marked Y. Linux uses it: setting
bits is a write of the mask at the register's offset plus 0x800, and
clearing bits is a write of the mask at offset plus 0xc00; plain read/write
is at offset plus 0 (`rp1.c:52-54`, `:96`, `:101`). It never read-modify-
writes MSIX_CFG. The generic atomic-alias scheme itself is described in the
PDF's address-map chapter (not re-read here; **inference** that 0x800 is
set and 0xc00 is clear aliases, taken from how Linux uses them).

### The acknowledge protocol, as Linux runs it

All of it is in `rp1.c`; Linux builds a 61-vector interrupt domain over the
61 MSI-X vectors it allocates (`rp1.c:284-289`, `:320-321`, `:328-341`).

1. Enable: when a peripheral's interrupt is activated, Linux sets ENABLE
   in that vector's MSIX_CFG, then activates the matching parent MSI-X
   vector (`rp1.c:200-209`). On deactivation it clears ENABLE (`:211-219`).
2. Trigger type: the device-tree interrupt type decides whether the vector
   uses the acknowledge function. A level-high peripheral (type level high)
   sets IACK_EN; an edge-rising peripheral clears IACK_EN; any other type is
   refused (`rp1.c:120-142`). Linux remembers per vector whether it is a level
   vector (`:173`).
3. Handling: the parent MSI-X handler maps the arriving vector number
   (low 6 bits) to the RP1 interrupt, runs the peripheral's handler, and, if
   the vector is a level vector, then writes IACK to that vector's MSIX_CFG
   (`rp1.c:160-177`). With IACK_EN set the block masks the source line when
   the MSI goes out and re-arms it only on the IACK write; if the source
   line is still high at that moment, it sends a new MSI (`PDF:5597-5600`).
   Without IACK_EN the line is a plain edge: one MSI per rising edge.
4. Masking by the host is done at the parent MSI-X vector's own mask bit
   (the MSI-X table's vector mask), not in MSIX_CFG (`rp1.c:104-118`).

The PDF warns that level interrupts without IACK can be lost, and states that
the only true edge interrupts in RP1 are the USB host vectors (`PDF:858-861`,
`PDF:5602-5604`). In the Pi 5 tree the system-config, UART and Ethernet nodes use
level-high and the two USB nodes edge-rising (`rp1.dtsi:20`, `:65`,
`:1004`, `:1131`, `:1148`).

Where the MSI-X table and PBA live (the MSI-X capability's table and PBA
BAR indicator and offsets) is **not found**: Linux reads them through the
generic PCI MSI-X code. A probe of the capability will tell.

### Vector map (hardware interrupt numbers = MSI-X vector indices)

From `rp1-int.h` (the Interrupts block). Vector n is MSIX_CFG_n and the n-th
MSI-X table entry (the driver allocates 61 vectors and uses the index
directly: `rp1.c:192`, `:339`).

| peripheral | vector | trigger Linux sets |
|---|---|---|
| IO_BANK0, 1, 2 | 0, 1, 2 | level high |
| AUDIO_IN, AUDIO_OUT | 3, 4 | level high |
| PWM0 | 5 | level high |
| **ETH (Cadence GEM)** | **6** | level high (`rp1.dtsi:1004`) |
| I2C0..I2C6 | 7..13 | level high |
| I2S0..I2S2 | 14..16 | level high |
| SDIO0, SDIO1 | 17, 18 | level high |
| SPI0..SPI5 | 19..24 | level high |
| **UART0** | **25** | level high (`rp1.dtsi:65`) |
| TIMER_0..3 | 26..29 | |
| USBHOST0 (summary line) | 30 | |
| **USBHOST0_0** | **31** | edge rising, the only one Linux uses for controller 0 (`rp1.dtsi:1131`) |
| USBHOST0_1, _2, _3 | 32, 33, 34 | not used by Linux |
| USBHOST1 (summary line) | 35 | |
| **USBHOST1_0** | **36** | edge rising, the one Linux uses for controller 1 (`rp1.dtsi:1148`) |
| USBHOST1_1, _2, _3 | 37, 38, 39 | not used by Linux |
| DMA | 40 | |
| PWM1 | 41 | |
| **UART1..UART5** | **42, 43, 44, 45, 46** | level high (UART1 at `rp1.dtsi:82`) |
| MIPI0, MIPI1 | 47, 48 | |
| VIDEO_OUT | 49 | |
| PIO_0, PIO_1 | 50, 51 | |
| ADC_FIFO | 52 | |
| PCIE_OUT | 53 | |
| SPI6, SPI7, SPI8 | 54, 55, 56 | |
| PROC_MISC | 57 | |
| SYSCFG | 58 | level high |
| CLOCKS_DEFAULT | 59 | |
| VBUSCTRL | 60 | |

Note the UART numbering is not monotone: UART0 is vector 25 but UART1 to
UART5 are 42 to 46 (`rp1-int.h`). The PDF's section 6.2 says RP1 has 61
vectors and gives no map (`PDF:5583`), so this table's vector numbers have
only the Linux header as source. **Inference** from the PDF's "four interrupt
vectors per controller" (`PDF:4196`): USBHOST0_0..3 are the four vectors, and
the plain USBHOST0 line (30) is not one of them; Linux uses only the first of
each four, which works because dwc3 has a single event ring in its use.

Which UART reaches the Pi 5's debug connector: the board's debug UART is
`uart10` on the BCM2712 itself, not an RP1 UART (`rpi-5-b.dts`, the comment
above its `&uart10` node), so RP1's UARTs are not the console. They are
ARM PL011 instances (`compatible` "arm,pl011-axi" with primecell id 0x00341011
and a 0x100-byte register window at peripheral offset 0x30000 + 0x4000*n,
`rp1.dtsi:62-78`), clocked by the RP1 "uart" clock and the 100 MHz
`pll_sys_pri_ph` bus clock.

### RP1 power, clocks and reset (not in F3, noted because it gates F4/F5)

- Linux pulses a reset control on probe before touching RP1
  (`rp1.c:260-263`); that reset belongs to the host's PCIe side (F1's
  `pciex4_reset`).
- The board tree holds RP1's RUN pin high with a GPIO hog on the BCM2712's
  AON GPIO 2 (`rpi-5-b.dts:622-630`).
- RP1's clock tree is programmed by Linux's RP1 clock driver, which the
  device tree starts with fixed rates (`rp1.dtsi:24-60`): pll_sys_core 1 GHz,
  pll_audio_core 1.536 GHz, pll_sys 200 MHz, pll_sys_sec 125 MHz, clk_eth 125
  MHz, clk_sys 200 MHz, pll_sys_pri_ph 100 MHz, clk_eth_tsu 50 MHz, crystal
  50 MHz. Whether the firmware has already started these before the OS runs is
  **not found**. erXos's RP1 core must either read the clock bank at 0x18000
  to find out, or program it. Clock registers in `clk-rp1.c`: eth control
  0x64, eth divider 0x68, eth select 0x70; eth_tsu control 0x134, divider
  0x138, select 0x140; the USB host micro-frame and suspend clocks have
  registers at 0xf4..0x130 (`clk-rp1.c:65-67`, `:103-121`). The rp1_usb
  device-tree nodes carry no `clocks` property (`rp1.dtsi:1118-1148`), so
  Linux does not enable those clocks for dwc3; whether they run by default is
  **not found**.

## F4: RP1 Ethernet

### The GEM and its wrapper

- The MAC is the Cadence GEM_GXL version "1p09": 10/100/1000, RGMII only,
  half or full duplex, 64-bit MAC data bus, SRAM packet buffer DMA with 64-bit
  address and 128-bit data, AXI4 master, four address filters, jumbo frames to
  16383 bytes, internal loopback, store-and-forward only (no partial), and an
  IEEE 1588 timestamp unit (`PDF:5616-5629`). The PDF names the vendor manual
  "Cadence Gigabit Ethernet MAC with DMA, 1588, AVB and PCS (GEM_GXL) User
  Guide Rev 15" (`PDF:5637-5638`), not read here.
- GEM registers: base 0x100000 of BAR 1 (APB, `PDF:5656`), 0x4000 bytes
  (`rp1.dtsi:1000`). Interrupt: vector 6, level high with IACK (above).
- The wrapper's own registers, `eth_cfg` at 0x104000 (APB, atomic aliases
  supported, `PDF:5658`, `PDF:5661-5685`):

| offset | name | meaning |
|---|---|---|
| 0x00 | CONTROL | bit 4 MEM_PD memory power-down (reset 0); bit 3 BUSERR_EN let MAC bus errors reach the fabric (reset 0 = off); bits 2:1 TSU_INC_CTRL drive the GEM's TSU increment control; bit 0 TSU_MS drives the TSU master/slave pin |
| 0x04 | STATUS | read only: bit 0 RGMII link up; bits 2:1 RGMII speed (0 = 10M, 1 = 100M, 2 = 1G, reset 2); bit 3 RGMII duplex; bit 4 ARLEN_ILLEGAL and bit 5 AWLEN_ILLEGAL (illegal AXI read or write burst over 16 beats; the PDF says this needs a block reset and maybe a system reset) |
| 0x08, 0x0c, 0x10 | TSU_TIMER_CNT0, 1, 2 | the 94-bit TSU timer, read only: 31:0, 63:32, 29:0 |
| 0x14 | CLKGEN | RGMII transmit clock generator, "can be changed on the fly" |
| 0x18 | CLK2FC | frequency-counter clock select |
| 0x1c, 0x20, 0x24, 0x28 | INTR, INTE, INTF, INTS | wrapper interrupts: raw, enable, force, masked status (bit layout not read) |

CLKGEN (`PDF:5781-5821`): bit 9 TXCLKDELEN adds delay to the RGMII transmit
clock (reset 0); bit 8 DC50 duty-cycle correction for odd divisors (reset 0);
bit 7 ENABLE starts and stops the generator cleanly (reset 1); bit 6 KILL
stops it asynchronously (reset 0); bits 5:4 SPEED_FROM_MAC read only; bit 3
SPEED_OVERRIDE_EN use the speed in bits 1:0 instead of the MAC's (reset 0);
bits 1:0 SPEED_OVERRIDE (0 = 10M, 1 = 100M, 2 = 1000M; the register's
description names 1 as the default for the field). **Inference**: with the
reset values (ENABLE set, no override, no kill) the generator follows the speed
the MAC reports and needs no write.

### What Linux writes for RP1's Ethernet

- Linux's driver table entry for compatible "raspberrypi,rp1-gem"
  (the node's compatible list is "raspberrypi,rp1-gem", "cdns,macb";
  `rp1.dtsi:1000-1001`, `macb.c:5192-5199`, `:5223`) sets these capabilities:
  gigabit mode available, hardware-changed clock, jumbo frames, and PTP
  support (the timestamp unit); AXI burst length 16 in the DMA configuration;
  maximum jumbo length 10240 bytes; generic clock init and generic init;
  default user-IO bit layout.
- **No write to `eth_cfg` anywhere in these files.** `macb.c` has no
  reference to the wrapper's registers. Because the capability "clock hardware
  changed" is set, Linux does not set the transmit clock rate on link changes
  (`macb.c:540-546`): the CLKGEN block follows the MAC (above). The one clock
  Linux sets is the fixed 125 MHz `clk_eth` at boot through the device tree
  (`rp1.dtsi:24-60`; see F3's clocks note) and the 50 MHz TSU clock.
- Clocks the node lists, in order named pclk, hclk, tsu_clk, tx_clk:
  clk_sys, clk_sys, clk_eth_tsu, clk_eth (`rp1.dtsi:1005-1009`). The
  clk-init helper enables all that exist (`macb.c:4249-4300`).
- RGMII delay: the node's phy-mode is "rgmii-id" (`rp1.dtsi:1010`), which in
  Linux's convention means the PHY inserts both transmit and receive delays
  and the MAC adds none. Linux's driver never sets TXCLKDELEN. **Inference**:
  MAC-side delay is not used; the PHY's delays carry the timing.
- USRIO register (GEM offset 0x0c0, `macb.h:75`): for an RGMII interface
  Linux writes the value with bit 0 (the "RGMII" selector, `macb.h:494`, and
  `macb.c:4467-4482`); no "clock enable" bit 1 because RP1's capability set
  lacks that flag.
- DMA configuration (GEM offset 0x010): address-bus-width bit 30 is set when
  the design register says the hardware has 64-bit addressing. The test is
  DCFG6 (GEM offset 0x294) bit 23 "DAW64" (`macb.h:89`, `:184`, `:350`, `:551`;
  `macb.c:5373-5374`). When set Linux uses 64-bit buffer descriptors (each
  descriptor carries a high-address word) and a 44-bit DMA mask
  (`macb.c:2925-2935`, `:5373-5380`). **Inference**: RP1's GEM reports DAW64,
  since the PDF says 64-bit DMA address; nothing here reads the register on
  hardware.
- AXI pipeline register AMP (GEM offset 0x054; `macb.h:89`): Linux writes
  fields only where the device tree gives them; RP1's node gives "cdns,aw2w-
  max-pipe" = 8, "cdns,ar2r-max-pipe" = 8 and the boolean "cdns,use-aw2b-
  fill" (`rp1.dtsi:1011-1013`). The fields: AR2R_MAX_PIPE bits 7:0 (maximum
  outstanding AXI read requests), AW2W_MAX_PIPE bits 15:8 (maximum
  outstanding write requests), AW2B_FILL bit 16 (select whether the write
  limit counts between the AW and W channels (0) or between AW and B (1)).
  So RP1: read 8, write 8, AW2B_FILL = 1 (`macb.h:354-361`; `macb.c:2950-2962`).
  The PDF's STATUS bits 4 and 5 show illegal AXI bursts over 16 beats are
  fatal until reset, which is why the DMA configuration burst length is 16
  (`macb.c:5195`).
- Interrupt moderation, checksum offload and the like are generic GEM
  features, not RP1 specifics, and not listed.

### PHY, MDIO and the reset line (Pi 5 board)

(`rpi-5-b.dts:169-181`, `:668`.)
- The PHY is at MDIO address 1; the node is named ethernet-phy@1 with reg 1.
- Properties on the PHY node: "brcm,powerdown-enable", "eee-broken-1000t",
  "eee-broken-100tx" (energy-efficient Ethernet is broken at 1000BASE-T and
  100BASE-TX, so do not advertise it), and "led-modes" = <0 8> (two LED mode
  numbers: LED 1 mode 0 and LED 2 mode 8, Broadcom numbering).
- The PHY's model number is **not found** in these files (the "brcm," prefix
  says Broadcom). The Pi 5's BCM54213PE is **unverified** here.
- PHY reset: RP1 GPIO 32, named "ETH_RST_N" in the board's pin-name list
  (`rpi-5-b.dts:668`), active low (`rpi-5-b.dts:172`), asserted for 5 ms
  (`phy-reset-duration`, `:173`). No post-reset delay property is given; Linux
  defaults it to 0 and the pre-delay to 10 ms if unspecified (`macb.c:5422-5436`).
  The sequence Linux runs when its MDIO bus is reset: drive the line to the
  asserted level, wait the duration, drive it to the idle level, wait the
  post-delay (`macb.c:504-510`). The GPIO is controlled through RP1's GPIO
  block (io_bank/pads/RIO), whose registers this record does not cover.
- MDIO is the GEM's own management port, with the standard clause 22
  frames; Linux selects the MDC divider from the clock rate (`macb.c:4484`
  area; not detailed). The PHY has no interrupt wired in the node.
- Unlisted: the `pads_eth` block (0xfc000) might need pad configuration for
  RGMII; Linux does not touch it in these files (**not found** any writer).

### FreeBSD's Cadence GEM driver

`FB:sys/dev/cadence/if_cgem.c` and `if_cgem_hw.h` (release/15.1.0, hashes
above). It is BSD-2-Clause, by Thomas Skibo, written for Zynq and ZynqMP.
Without summarizing its code: it attaches by device-tree compatible strings
"cdns,zynq-gem", "cdns,zynqmp-gem", "xlnx,zynq-gem", "xlnx,zynqmp-gem",
"microchip,mpfs-mss-gem", "sifive,fu540-c000-gem" and "sifive,fu740-c000-gem"
(`if_cgem.c:105-113`), with two hardware workaround flags (a receive-hang
workaround and a need for null extra queues; `:101-103`); it does not list
"cdns,macb" or "raspberrypi,rp1-gem". It reads the data bus width from design
configuration 1 and handles 32, 64 and 128 bits (`:1036-1048`); it picks
64-bit buffer descriptors at compile time when the CPU address space exceeds
32 bits (`:81-83`, `:1104-1106`), without reading DCFG6. It never writes the
AXI pipeline register or the user-IO register by name (no `AMP` or `USRIO`
matches), and has no PHY reset GPIO handling. So RP1 needs, on top of
FreeBSD's driver: an RP1 compatible entry, the AMP write (8, 8, fill 1), the
USRIO RGMII bit, the PHY reset line, the interrupt acknowledge through the
`erx_rp1` core, and the 125 MHz tx clock arrangement. GEM revision handled:
the Cadence "GEM" family in Zynq form (the module id register at 0x0fc,
`if_cgem_hw.h:237`); the RP1 revision "1p09" is not checked by it.

## F5: RP1 USB

### The controllers

- Two Synopsys dwc_usb3 v3.30b xHCI host controllers, each with one USB 2.0
  PHY and one USB 3.0 PHY (two downstream ports per controller), 64 device
  slots, 64 periodic endpoints, FIFOs enlarged (SuperSpeed 8 packets, High
  Speed 3 packets), four interrupt vectors each; no battery charging, no xHCI
  debug capability, no PHY VBUS sensing, no device mode (`PDF:4187-4203`).
- Registers: controller 0 at BAR 1 offset 0x200000, controller 1 at 0x300000,
  1 MiB each (AXI, no atomic aliases); their `usbhost0_cfg` and `usbhost1_cfg`
  at 0x160000 and 0x164000 (APB, atomic aliases supported) (`PDF:4212-4218`,
  `rp1.dtsi:1119`, `:1136`). The DWC3 global registers sit at offset 0xc100
  and up inside each controller's window (the standard DWC3 layout, e.g. GCTL
  at 0xc110; `dwc3-core.h:98-105`, `FB:dwc3.h:41-64`).
- Vectors: USBHOST0_0 = 31 and USBHOST1_0 = 36, edge rising, one per
  controller (F3 table).

### usbhostN_cfg writes before xHCI runs

**Not found.** The RP1 PDF lists the two cfg blocks only in the address map
(`PDF:4212-4214`) and documents no registers for them. The Pi 5 device tree
gives the USB nodes no reference to them (no `reg` window, no syscon phandle;
`rp1.dtsi:1118-1148`). The Linux files read (rp1.c, dwc3 core and host, the
trees above) contain no write to a `usbhost` cfg block. The nodes use the
plain compatible "snps,dwc3", so Linux uses no RP1-specific glue for USB.
**Inference**: the firmware leaves the controllers ready, or the defaults
suffice. A board probe must confirm, and the vendor's 'VBUSCTRL' block at
0x170000 (and the BCM2712 pin function "vbus1" on RP1 GPIO 42 and 43,
below) are the only other USB-related hardware named.

Board-level USB power: the first controller's node selects a pinctrl state
"usb_vbus_pins" which sets pins GPIO42 and GPIO43 of RP1 to function "vbus1"
(`rpi-5-b.dts:197-201`, `:692-695`); the pin-name list names GPIO42
"USB_VBUS_EN" and GPIO43 "USB_OC_N", GPIO49 "EN_MAX_USB_CUR"
(`rpi-5-b.dts:679-680`, `:686`). The second controller's node carries no
pinctrl. So VBUS enable and over-current go through RP1's IO bank pin
function "vbus1", driven by the `vbusctrl` block (offset 0x170000) whose
registers are not documented in the PDF text read (`PDF:545` lists it).

### DWC3 properties `rp1.dtsi` sets (both controllers identically)

(`rp1.dtsi:1118-1148`.) For each, what Linux's dwc3 core does
(`dwc3-core.c`, called during core init; the order in the init sequence is
the table's order only where noted).

| property | value | what the driver does |
|---|---|---|
| dr_mode | "host" | host only; the controller never runs device or OTG role (`dwc3-core.c`; the PDF says there is no device mode) |
| usb3-lpm-capable | present | **Inference, from the code read:** `dwc3-core.c:1776-1777` reads the property under the name "snps,usb3_lpm_capable", which is not what the node spells, so the dwc3 core does not set its own flag; `dwc3-host.c:177-178` forwards a "usb3-lpm-capable" property to the xHCI child only when that flag is set. So whether xHCI sees LPM-capable depends on the xHCI side, not read here. Net effect in this tree: probably none from this property at the dwc3 layer. |
| snps,axi-pipe-limit | 8 (a u8) | writes the AXI "pipelined transfer limit" field, bits 11:8 of GSBUSCFG1 (offset 0xc104), with the value minus 1, i.e. 7; refuses and logs if the property is above 16; skipped if zero (`dwc3-core.c:1325-1340`, `dwc3-core.h:99`, `:203`). Called in core init just before PHY power-on (`:1410`). |
| snps,dis_rxdet_inp3_quirk | present | sets bit 28 (DISRXDETINP3) in GUSB3PIPECTL(0) (offset 0xc2c0): disable receiver detection while the link is in the P3 power state. Done in the USB3 PHY configuration step, after clearing the suspend-enable bit (`dwc3-core.c:681-682`, `dwc3-core.h:333`). |
| snps,enhanced-nak-fs-quirk | present | sets bit 19 (NAK_PER_ENH_FS) in GUCTL1 (offset 0xc11c): enhanced NAK handling for full-speed bulk endpoints (`dwc3-core.c:1485-1486`, `dwc3-core.h:286`). Its sibling "snps,enhanced-nak-hs-quirk" (bit 18, high speed) is not set. |
| snps,parkmode-disable-ss-quirk | present | sets bit 17 (PARKMODE_DISABLE_SS) in GUCTL1: turn off the xHCI bus-parking optimization for SuperSpeed (`dwc3-core.c:1491-1492`, `dwc3-core.h:288`). |
| snps,parkmode-disable-hs-quirk | present | sets bit 16 (PARKMODE_DISABLE_HS) in GUCTL1, same for High Speed (`dwc3-core.c:1494-1495`, `dwc3-core.h:289`). |
| snps,parkmode-disable-fsls-quirk | present | sets bit 15 (PARKMODE_DISABLE_FSLS) in GUCTL1, same for Full and Low Speed (`dwc3-core.c:1497-1498`, `dwc3-core.h:290`). |
| snps,tx-max-burst | 8 (u8) | transmit threshold maximum burst size, GTXTHRCFG (offset 0xc108) bits 23:16 (`dwc3-core.h:232`). |
| snps,tx-thr-num-pkt | 2 (u8) | transmit threshold packet count, GTXTHRCFG bits 27:24, and bit 29 (PKTCNTSEL) set to select packet-count mode (`dwc3-core.h:233-234`). Both this and tx-max-burst must be nonzero or neither is written. Because the RP1 core is the plain DWC3 IP (v3.30b, not DWC_usb31), Linux takes its original-IP branch of the threshold setup (`dwc3-core.c:1268-1295`), not the periodic variant. No receive threshold is set. |
| interrupts | the one vector above, edge rising | one event interrupt; see F3. |

All GUCTL1 writes are a read-modify-write of the register that Linux
performs only when the core version is at least 2.50a (`dwc3-core.c:1478`,
condition read at `:1471-1477`); the RP1 core is 3.30b so they apply.

### FreeBSD's DWC3 driver and which quirks it implements

`FB:sys/dev/usb/controller/dwc3/dwc3.c` and `dwc3.h` (release/15.1.0). It
attaches by FDT compatible "snps,dwc3" (`dwc3.c:523-526`), which is what the
RP1 nodes use, so it would match them. It sets host role in GCTL, soft-resets
the core and both PHYs, sets GUCTL's host-auto-retry bit, programs the USB2
PHY width and turnaround time from a "phy_type" property, then starts a
generic xHCI (`dwc3.c:236-286`, `:298-305`, `:113-167`). Of RP1's property
list it implements exactly one: **snps,dis_rxdet_inp3_quirk** (sets bit 28 of
GUSB3PIPECTL0, `dwc3.c:348-349`, `dwc3.h:107`). It does **not** implement
snps,axi-pipe-limit (it never touches GSBUSCFG1), the enhanced-NAK quirks, the
three park-mode disables (it only defines two GUCTL1 bits, the IPGAP line-check
disable and a device-mode clock bit; `dwc3.h:58-59`), the transmit threshold
properties (it never touches GTXTHRCFG), or "usb3-lpm-capable". It implements
other properties RP1 does not set (the U2 free-clock, U2 and U3 suspend, LPM
enable, TX IPGAP line check and delayed P1 transition quirks;
`dwc3.c:325-352`).

Whether the unimplemented quirks matter for function (as opposed to
throughput or robustness under load) is **not found**; the Linux commit
history is not part of the sources read. A board probe can run without them
first.

## Fact groups at a glance

| group | state |
|---|---|
| F3 vendor/device ids, chip id registers | found |
| F3 BAR 1 = peripherals, BAR 2 = 64 KiB shared SRAM | found (PDF) |
| F3 BAR 0 role, all BAR sizes, MSI-X table/PBA location | not found |
| F3 MSIX_CFG register and acknowledge protocol | found (PDF + Linux) |
| F3 vector numbers of GEM (6), UART0 (25), USB0 (31), USB1 (36), UART1..5 (42..46) | found (Linux header only; PDF gives no map) |
| F4 eth_cfg registers, GEM revision and features | found (PDF) |
| F4 RP1 GEM setup (AMP 8/8/fill, USRIO RGMII, 64-bit descriptors, caps) | found (Linux) |
| F4 PHY at MDIO 1, reset on RP1 GPIO 32 active low 5 ms, phy-mode rgmii-id | found (Pi 5 tree) |
| F4 PHY model number, pads_eth setup, whether firmware starts the clocks | not found |
| F4 FreeBSD GEM driver fetched, scope stated | found |
| F5 usbhostN_cfg writes | not found (none in Linux; PDF has no registers) |
| F5 dwc3 property effects | found |
| F5 FreeBSD dwc3 fetched, quirks implemented | found: only dis_rxdet_inp3 |
| F5 VBUS control registers (vbusctrl block), USB clock defaults | not found |
