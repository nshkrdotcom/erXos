# Raspberry Pi 5 board tree, SD controller, watchdog and RNG: facts record (clean room)

A point-in-time research record, written on 2026-11-21 on the Apple Silicon
macOS development host whose scratch directory holds the sources listed
below. It is the clean-room half of the Raspberry Pi 5 work for facts F6
(microSD controller), F7 (board tree) and F8 (power-management watchdog and
RNG200 windows): what the Raspberry Pi downstream Linux tree's device tree
and SD host driver say, plus two non-GPL sources (TF-A 2.15.0 and Raspberry
Pi's documentation). Design and code agents read this record, never the
Linux sources. It states hardware facts in its own words: no code, no copied
comments, and no identifiers from Linux except register, node, property and
compatible names, which are hardware or interface facts.

Statements marked **inference** are my reading of a name or arithmetic on
cited values. Statements marked **not found** could not be established from
these sources.

Citation form: `RPI:file:line` is the Raspberry Pi downstream Linux tree at
the pinned commit; `TFA:file:line` is TF-A v2.15.0; `DOC:file:line` is
Raspberry Pi's documentation. Short names: `5b.dts` =
arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts, `rpi.dtsi` =
bcm2712-rpi.dtsi, `ds.dtsi` = bcm2712-ds.dtsi, `soc.dtsi` = bcm2712.dtsi
(same directory), `sdhci.c` = drivers/mmc/host/sdhci-brcmstb.c.

## Sources

All fetched over HTTPS on 2026-11-21 (read as data, nothing run).

**Raspberry Pi Linux**, commit `ea17ae02ca28483e508b05c7c44190c01a1ef8eb`
(the commit the BCM2711 PCIe record uses; the commit author date is
2026-10-15), from
`https://raw.githubusercontent.com/raspberrypi/linux/<commit>/<path>` into
`~/erxos-scratch/sources/rpi-linux-pi5-board/`:

| SHA-256 | path |
|---|---|
| b90fe894f860fac4f99f6be31d7d696bab8c2a5871b2ac1a25a29c3386ba59d3 | arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts |
| 2dfcfb67316b9098c15a0cd6c9213d698dc0b2556c26bb247115a8450269ca29 | arch/arm64/boot/dts/broadcom/bcm2712-ds.dtsi |
| 6d09493a2912d8e616d2dbefe49892591023fb7d47ab08c61cb741da4fc681f0 | arch/arm64/boot/dts/broadcom/bcm2712-rpi.dtsi |
| 528db3391562b79470028ca60fa86e710a27258d52caca407c4d11248ac9ce88 | arch/arm64/boot/dts/broadcom/bcm2712.dtsi |
| e8c537ab4f2a9b1a62ec8284c45085a3767d2316b0ad921a1d9f5fcfdfbda45a | arch/arm64/boot/dts/broadcom/rp1.dtsi |
| bd97a9e44686112354dfc17e7af54cec6eba67a2afdd06ce7110c838642ec87b | arch/arm64/boot/dts/broadcom/bcm2712-rpi-cm5.dtsi (license read only) |
| 45a15c9bc1250c9aaeb1f8227f119fe7560d5939abada52eed72cc153b33b532 | drivers/mmc/host/sdhci-brcmstb.c |
| eae21118acf3c5ec97e48b81424cbaadeb9391f3a5cba3b8aba7badb3a62d2e6 | include/dt-bindings/power/raspberrypi-power.h |
| 7f76b7b4f29c24cc87710f60cff99e0ac571ed7b6fa69dc127ae370dabd8546a | include/dt-bindings/pwm/pwm.h |
| 80dc56e8aa61b3681ee42fb0bfd34bf35ea2578ac6d82f1fa972b963667e8ff7 | include/dt-bindings/interrupt-controller/arm-gic.h |
| 392400a309a54ea5b1a2ac2e52773d3ab68e07323109b9aed88a69fedc74e082 | include/dt-bindings/interrupt-controller/irq.h |
| afbc90d64fc82a3e0a2de961a3c845c78971695b565d2c7f4683db8fdb3f008f | include/dt-bindings/soc/bcm2835-pm.h |
| b5fed4b44b6e23a3e8596cf3de21d06586ae7ea74289515a5ec6775bf8d2b5b9 | include/dt-bindings/reset/raspberrypi,firmware-reset.h |
| 5423b3866877ead0920ec978b5b072f06087443033a72445b39faed8f288ddc1 | include/dt-bindings/gpio/gpio.h |
| 8e454c1af9fd4e87e05d03ca2de029c217917a6e1ae997e9d61c1bd63ba4e214 | include/dt-bindings/mfd/rp1.h |
| ba427771249297a45ef7978a390ba3c4bcdb0f526e32f035e200fcc074f01c69 | include/dt-bindings/clock/rp1.h |

Also read for comparison only (the existing BCM2711 sources, hashes in
research-brcmstb-pcie.md's source list; not refetched):
`~/erxos-scratch/sources/linux-brcmstb/rpi-ea17ae02/arch/arm/boot/dts/broadcom/bcm2711.dtsi`.
No node of the RNG200 sources directory was opened.

**TF-A v2.15.0** (tag object `9ad327a8d124ce82002614c23e33992d4de6f7cf`,
tag date 2026-05-29; BSD-3-Clause), from
`https://raw.githubusercontent.com/ARM-software/arm-trusted-firmware/v2.15.0/<path>`
into `~/erxos-scratch/sources/tfa-2.15.0-rpi5/`:

| SHA-256 | path |
|---|---|
| bbf12ec75f6082a5db9dd898625b6fcb9191ef3928a0f8ef9eb1eaeb1d43dcf4 | docs/plat/rpi5.rst |
| 8a1fd4315a9372a66845e25dc37bf171f1a743830a31665cae93dd284ae0dd58 | plat/rpi/rpi5/platform.mk |
| 03f7cfd156a632313ebce57740d39fa9e1b29abcb30ac5618c4e237f20c9afbb | plat/rpi/rpi5/rpi5_setup.c |
| 73d5fae82d47783840c438fb56747d3b464ef66e5fd71e4eeff02c45ce2b34f0 | plat/rpi/rpi5/include/platform_def.h |
| 6dfb6ccf4829435f87f7ad91f137cab3eccb1895fff2ca0b8b5cf78be66af7c9 | plat/rpi/rpi5/include/rpi_hw.h |
| 1385a4dd5fd098ae913ab5758ac87f4e672ed02a146376590125c4dc732cd15e | plat/rpi/rpi5/include/plat.ld.S |
| 8f3ff9c6177ecdaf350db9906726d313adef00b314740ad6a24fe23505be623e | plat/rpi/common/rpi4_bl31_setup.c |

**Raspberry Pi documentation**, commit
`c6a64966af136da21a1e55551c5a395cb6987fce` (2026-11-13), in
`~/erxos-scratch/sources/rpi-documentation/`, paths under
documentation/asciidoc/computers/:

| SHA-256 | file here (published path) |
|---|---|
| d4be7bf9a1e29c09c4592176d04cd8bc4ff146d8f38fe03108e738fa5aa1fee3 | config_txt_boot.adoc (config_txt/boot.adoc) |
| ee9b8fea18861211d7fa5073bfa81ed1a938f3e49ccfefd966653ed3c56c9443 | config_txt_video.adoc (config_txt/video.adoc) |
| 417d7ed1624d7facce253cdc95f9cfe92bdf11a2498f538d366948989ccc1f07 | config_txt_memory.adoc (config_txt/memory.adoc) |
| 89f471a14be1243320220c5a6114998e961263561c88db42c6e75b5f7aa8de68 | legacy_config_txt_boot.adoc (legacy_config_txt/boot.adoc) |

## Address convention used by the board tree

Peripheral nodes sit under a `soc` bus whose translation maps child address 0
to physical 0x10_0000_0000 for a 2 GiB window (`soc.dtsi:189-191`; the node's
own unit address `107c000000` is only its name). Every `reg` below under that
bus is therefore a child address; the physical address adds
0x10_0000_0000. Nodes under the `axi` bus (`soc.dtsi:424`) use two address
cells and give the physical address directly. TF-A states the same bases: its
peripheral window starts at 0x10_0000_0000 and is 0x10_0000_0000 long
(`TFA:rpi_hw.h`, RPI_IO_BASE/RPI_IO_SIZE).

## F7: the board tree

### Includes and licenses

`5b.dts` includes, in order: seven kernel binding headers and
`bcm2712-ds.dtsi` (line 11); `rp1.dtsi` at line 133, mid-file; and
`bcm2712-rpi.dtsi` at line 206 (`5b.dts:4-11,133,206`). `ds.dtsi` includes
`bcm2712.dtsi` and one more binding header (`ds.dtsi:2-4`). `rp1.dtsi`
includes three binding headers (`rp1.dtsi:1-3`); `rpi.dtsi` one (`rpi.dtsi:3`).

SPDX identifiers, first line of each file read:

| file | SPDX |
|---|---|
| bcm2712-rpi-5-b.dts | (GPL-2.0 OR MIT) |
| bcm2712-ds.dtsi | GPL-2.0 (only) |
| bcm2712-rpi.dtsi | GPL-2.0 (only) |
| bcm2712.dtsi | (GPL-2.0 OR MIT) |
| rp1.dtsi | **none**: the file carries no SPDX line and no license text in its first lines or anywhere a search for "SPDX" found (not found) |
| dt-bindings/power/raspberrypi-power.h | GPL-2.0 |
| dt-bindings/pwm/pwm.h | GPL-2.0 |
| dt-bindings/reset/raspberrypi,firmware-reset.h | GPL-2.0 |
| dt-bindings/mfd/rp1.h | GPL-2.0 |
| dt-bindings/clock/rp1.h | GPL-2.0 |
| dt-bindings/soc/bcm2835-pm.h | (GPL-2.0+ OR MIT) |
| dt-bindings/interrupt-controller/irq.h | GPL-2.0 OR MIT |
| dt-bindings/interrupt-controller/arm-gic.h | GPL-2.0 OR MIT |
| dt-bindings/gpio/gpio.h | (GPL-2.0 OR BSD-2-Clause) |

Consequence (inference): the compiled Pi 5 tree is a combination that is not
permissive throughout. `bcm2712-ds.dtsi`, `bcm2712-rpi.dtsi`, `rp1.dtsi`
(unlicensed) and five binding headers are GPL-2.0 only or without a stated
license; the permissive "OR MIT" choice exists only for the board file, the
SoC file and three headers. The compute module file `bcm2712-rpi-cm5.dtsi`
is (GPL-2.0 OR MIT) but includes the same `ds.dtsi`, `rp1.dtsi` and
`rpi.dtsi` (`bcm2712-rpi-cm5.dtsi:1,10,120,196`), so it does not help. A
permissive tree needs the SoC's own nodes written from this record, not
the shipped files. I did not run a preprocessor, so which header constants
the compiled output really needs is not checked.

### Debug UART

- The debug UART is node `uart10`, a PL011 under `soc`, `reg` child address
  0x7d001000 size 0x200 (physical 0x10_7d001000), interrupt SPI 121 level
  high, `status` disabled in the SoC file and enabled by the board file
  (`soc.dtsi:236-243`, `5b.dts:183-187`). `ds.dtsi` sets its compatible list
  to the AXI-attached PL011 variant first, then plain PL011, then primecell
  (`ds.dtsi:424-426`); `soc.dtsi` has "arm,pl011", "arm,primecell". The node's
  primecell peripheral id is set to 0x00341011 by the tree.
- Clocks of the node: UART clock `clk_uart`, a fixed clock of 9216000 Hz;
  APB clock `clk_vpu`, fixed 750000000 Hz (`soc.dtsi:20-34,240-241`). The
  board comment calls it the debug UART on the 3-pin JST-SH connector
  labelled "UART" (`5b.dts:183-185`).
- Surprise: TF-A states the UART clock as 44000000 Hz and the same
  base 0x10_7d001000 (`TFA:rpi_hw.h`, RPI4_PL011_UART_BASE and CLOCK; baud
  115200 in `platform_def.h`). The tree's 9.216 MHz does not match. Which is
  true on the board, and whether the firmware reprograms the clock before
  handoff, is **not found**; a probe must settle it.
- Aliases: `serial10` and `uart10` and `console` all name `uart10`;
  `serial0`-`serial4` and `uart0`-`uart4` name RP1's UARTs (`rpi.dtsi:126-171`).
  Another UART `uarta` (compatible bcm7271 UART, at 0x7d50c000) is the
  Bluetooth module's, with RTS/CTS (`ds.dtsi:196-199`, `5b.dts:365-371`).
- `/chosen/stdout-path` is a static property of the tree: the string
  "serial10:115200n8" in node `chosen` in `rpi.dtsi:121-124`, together with a
  `bootargs` property. It is not added by an overlay in these files. Whether
  the firmware rewrites it at boot is **not found** (nothing in the read
  Raspberry Pi documentation says so).

### ACT LED

Node `led-act`, label "ACT", is a gpio-leds entry on the always-on GPIO bank
`gio_aon`, line 9, active low, default off, default trigger "mmc0"
(`5b.dts:20-39`). `gio_aon` is a brcm brcmstb GPIO bank at child address
0x7d517c00, size 0x40 (physical 0x10_7d517c00), two banks of 17 and 6 lines,
and is deliberately not an interrupt controller because the VPU firmware
monitors the PMIC interrupt (`soc.dtsi:254-262`, `ds.dtsi:432-435`). The
power LED is a different part: RP1 GPIO 44, active low (`5b.dts:25-29`).
Board-level override of the ACT line is a firmware parameter (`act_led_gpio`)
of the tree's override block (`rpi.dtsi`, `__overrides__`).

### pcie2 (the link to RP1)

Node `pcie2`, compatible "brcm,bcm2712-pcie", `reg` 0x10_0012_0000 size
0x9310 (two address cells, physical directly), PCI domain 2, max link speed
setting 2 (gen 2 value), 4 lanes, interrupts "pcie" SPI 233 and "msi" SPI
234 (`soc.dtsi:521-534`). Legacy INTx lines 1-4 map to SPI 229-232
(`soc.dtsi:536-539`). Reset lines: rescal controller and `bcm_reset` line 44
named "bridge" (`soc.dtsi:540-541`). MSI controller is `mip0` (a
"brcm,bcm2712-mip": registers 0x10_0013_0000 size 0xc0 plus a window at
PCI address 0xff_ffff_f000 size 0x1000; MSI SPIs from 128, 64 vectors),
referenced as msi-parent (`soc.dtsi:543,562-570`).

Ranges (PCI address to CPU address, size), flags 0x02000000 = 32-bit
non-prefetchable, 0x43000000 = 64-bit prefetchable, 0x03000000 = 64-bit
non-prefetchable (`soc.dtsi:545-549`):

| PCI address | CPU address | size | kind |
|---|---|---|---|
| 0x0_0000_0000 | 0x1f_0000_0000 | 0xfffffffc (about 4 GiB) | 32-bit, non-prefetchable |
| 0x4_0000_0000 | 0x1c_0000_0000 | 0x3_0000_0000 (12 GiB) | 64-bit, prefetchable |

Inbound (`dma-ranges`, PCI address to CPU address, size)
(`soc.dtsi:551-557`):

| PCI address | CPU address | size | kind |
|---|---|---|---|
| 0x0_0000_0000 | 0x1f_0000_0000 | 0x400000 (4 MiB) | 32-bit, non-prefetchable |
| 0x10_0000_0000 | 0x0 | 0x10_0000_0000 (64 GiB) | 64-bit, prefetchable |
| 0xff_ffff_f000 | 0x10_0013_0000 | 0x1000 | 64-bit non-prefetchable: the MSI doorbell of `mip0` |

The board file enables it, sets "aspm-no-l0s" and a vdm-qos-map of eight
values (8 8 8 9 10 10 11 11) (`5b.dts:120-124,764-766`; `ds.dtsi:490-493`).
The board file calls `pcie2` the RP1 target (`rp1_target`): `rp1.dtsi` attaches
RP1 there. Other Raspberry Pi names: `pciex4` is `pcie2`, `pciex1` is `pcie1`
(`rpi.dtsi:266-267`). `pcie1` (the external x1 connector) has its own ranges
(`ds.dtsi:481-488`) and a fifo-qos-map (`5b.dts:126-128`); not studied further.

### simple-framebuffer

**No `simple-framebuffer` node exists** in the five Pi 5 board tree files, in
`rp1.dtsi`, or in the BCM2711 files read, and none of the Raspberry Pi
documentation read mentions one (searched all of those and the
`rpi-firmware-wiki` directory for "simple-framebuffer", "simplefb"; not
found). The tree has only a node `fb` with compatible "brcm,bcm2708-fb"
and a `firmware` link to the firmware mailbox node (`rpi.dtsi:37-40`),
aliased `fb` (`rpi.dtsi:134`); that is a driver for asking the firmware to
allocate a framebuffer, not a described one. Whether the firmware adds a
simple-framebuffer node to the tree it hands over is **not found**: it is not
in the tree and not in the documentation read. A probe must dump the tree the
firmware passes on the board. Related documentation fact: the firmware picks
an HDMI mode from the display's EDID and passes it on the kernel command
line unless `disable_fw_kms_setup` is set (`DOC:config_txt_video.adoc:106-108`).

### Other board-tree facts relevant to later work

- The SoC's memory node is "filled by the bootloader" (`5b.dts:14-18`).
- The firmware mailbox, `brcm,bcm2835-mbox`, is at child address 0x7c013880
  size 0x40 (physical 0x10_7c013880), SPI 33 (`soc.dtsi:~228-234`); TF-A
  uses the same address (`TFA:rpi_hw.h`).
- The interrupt controller is a GICv2 (`gicv2`); TF-A states GICD at
  0x10_7fff9000 and GICC at 0x10_7fffa000 (`TFA:rpi_hw.h`).
- The system timer is at 0x7c003000 with clock 1 MHz (`soc.dtsi`), and
  TF-A states the generic counter frequency as 54000000 (`TFA:platform_def.h`).
- Fixed regulators: "3v3" and "5v0" are notional, for overlays
  (`rpi.dtsi:78-93`).

## F6: the microSD slot

### Controller

The microSD slot is on `sdio1`, aliased `mmc0` (`rpi.dtsi:151`), commented
in the board file "SDIO1 is used to drive the SD card" (`5b.dts:312`). It is an
SDHCI-compatible controller of the Broadcom set-top-box family: compatible
list "brcm,bcm2712-sdhci" then "brcm,sdhci-brcmstb" (`soc.dtsi:201-203`).

Registers (child addresses under `soc`; physical = + 0x10_0000_0000)
(`soc.dtsi:204-207`):

| name | child address | size | physical |
|---|---|---|---|
| "host" (standard SDHCI register block) | 0x00fff000 | 0x260 | 0x10_00fff000 |
| "cfg" (Broadcom configuration block) | 0x00fff400 | 0x200 | 0x10_00fff400 |

Interrupt: SPI 273, level high. Clock: `clk_emmc2`, a fixed clock of
200000000 Hz named "sw_sdio" for this node (`soc.dtsi:35-40,208-209`).
A second controller `sdio2` is at 0x10_0110_0000 (host size 0x260) and
0x10_0110_0400 (cfg size 0x200), SPI 274, same clock, with CQE support and a
capability mask; it is disabled by default, and the board file uses it for
the on-board Wi-Fi (`ds.dtsi:388-399`, `5b.dts:423-434`); it is not the SD
slot.

### Board properties of `sdio1` (`5b.dts:312-325`)

- Bus width 4. UHS modes enabled in the tree: SDR50, DDR50, SDR104. DDR at
  3.3 V is allowed (property "mmc-ddr-3_3v", `soc.dtsi:210`). Command-queue
  support is set to 1 (`supports-cqe`), meaningful for eMMC; whether it matters
  for an SD card is **not found** (inference: no, it is set because the node
  is shared with CM5 eMMC use).
- Card detect: GPIO `gio_aon` line 5, active low, with pin function
  `sd_card_g` on pad `aon_gpio5` and pull-up (`5b.dts:323,328-333`).
- Pull-ups on the command line and data lines 0-3 (pads "emmc_cmd",
  "emmc_dat0".."emmc_dat3") (`5b.dts:359-362`).
- Card power ("vmmc"): fixed 3.3 V regulator "vcc-sd", enabled by `gio_aon`
  line 4, active high (`5b.dts:54-61`).
- Signal level ("vqmmc"): a GPIO-switched regulator "vdd-sd-io" selecting
  1.8 V when `gio_aon` line 3 is high (value 1) and 3.3 V when low (value 0),
  settling time 5000 us, marked on at boot and always on (`5b.dts:41-52`).
- All three lines (3, 4, 5) are on the always-on bank at 0x10_7d517c00,
  the same bank as the ACT LED (line 9).

### Broadcom configuration registers ("cfg" block) used by the driver

Offsets in the cfg block, from `sdhci.c:40-51`:

| offset | name | bits used |
|---|---|---|
| 0x00 | CTRL | bit 31 SDCD_N test enable; bit 30 SDCD_N test level |
| 0x44 | SD_PIN_SEL | bits 1:0 mask; bit 1 = SD pin set; bit 0 = MMC pin set |
| 0x4c | CQ_CAPABILITY | bits from 12 up: timer-frequency multiplier; low bits: base clock MHz |
| 0x1ac | MAX_50MHZ_MODE | bit 31 strap override; bit 0 enable |

(Offsets 0x1ac name and bit meanings are read from macro names; their
purpose is partly **inference** from how the driver uses them.)

Behavior of the 2712 variant of the driver, in prose:

1. At controller setup (`sdhci.c:260-296`): if the node asks for any mode
   that needs tuning (UHS SDR50 or SDR104, or an eMMC HS200/HS400 mode), the
   driver clears the MAX_50MHZ_MODE enable bit and sets its strap-override
   bit, to select the delay-line PHY as the clock source. If the node is
   non-removable or needs polling, it clears the CTRL test-level bit and
   sets the test-enable bit (forcing "card present"); this does not apply to
   the Pi 5's SD slot, which has a card-detect line. Finally it writes
   CQ_CAPABILITY with multiplier value 3 and the base clock in MHz taken
   from the clock rate (never below 1) (`sdhci.c:292-295`).
2. On every clock change (`sdhci.c:155-189`): the driver first writes zero to
   the standard clock control register, then rewrites the SD_PIN_SEL low two
   bits: MMC pin set for the timings eMMC legacy HS, DDR52, HS200 and
   HS400, SD pin set for all others (so SD cards use the SD pin set, which
   includes SD default speed, high speed and UHS). A clock of zero stops
   there; otherwise it computes the divider with the standard SDHCI routine
   and enables the clock.
3. Power: before the standard power-on, it sets the card's vmmc regulator to
   the supply voltage requested (`sdhci.c:206-215`).
4. Reset: after the standard and CQE reset it re-enables automatic clock
   gating, only if the gating flag is set for the node; the flag is set only
   for non-removable devices and only if the match record has the
   clock-gate flag, which the 2712 record does not (`sdhci.c:74-95,
   661-668,469-472`). So gating is not used for the SD slot.
5. The 2712 match record sets only the "use card busy" flag (`sdhci.c:469-473`).
   The driver clears the host's reported UHS capability bits (SDR50, SDR104,
   DDR50) after reading capabilities and lets the tree choose them, and it
   sets the quirk that presets are broken only if a "clock-frequency"
   property rewrites the base clock (`sdhci.c:690-730`). The Pi 5 tree
   has no "clock-frequency" on `sdio1`, so presets are not marked broken
   by this path (inference from reading the node; the generic SDHCI
   preset behavior is not described here).
6. HS400-to-lower downgrade: the controller's PHY refuses configuration
   changes for high-speed timings while the clock is above 52 MHz, so the
   driver drops the clock to 52 MHz first (`sdhci.c:246-258`). This
   concerns eMMC, not the Pi 5's slot.
7. Vendor register in the host block at offset 0x78: bit 0 enhanced strobe,
   bit 1 gate SD clock (`sdhci.c:22-24`).
8. SD Express (PCIe-over-SD) code exists in the driver with extra pinctrl
   and a "sde-1v8" regulator; the Pi 5 `sdio1` node defines none of the
   pinctrl states or that regulator, so it is not active (`sdhci.c:298-340,
   627`; node properties above). Whether the Pi 5 slot's hardware supports
   SD Express is **not found**.

Quirks found: the sampling-clock/PHY handling above; controller base
clock is taken from the 200 MHz fixed clock; no other 2712-specific quirk
flag is set. Not found: the exact reset time, the maximum clock the PHY
accepts in SD mode, and any errata beyond what the code handles; DMA mode
(SDMA/ADMA2 and the DMA addressing limits) of this controller is also not
settled here: the driver clears the 64-bit-capable bit only for match
records with a no-64-bit flag, which the 2712 record lacks.

## F8: PM watchdog and RNG200 at the BCM2712 addresses

Both nodes are in `ds.dtsi` under `soc`.

| item | BCM2712 | BCM2711 |
|---|---|---|
| watchdog node | `pm: watchdog@7d200000` | `pm: watchdog@7e100000` |
| compatible | "brcm,bcm2712-pm" only | "brcm,bcm2711-pm", "brcm,bcm2835-pm-wdt" |
| reg | 0x7d200000 size 0x308 (physical 0x10_7d200000) | 0x7e100000 size 0x114; 0x7e00a000 size 0x24; 0x7ec11000 size 0x20 |
| reg-names | "pm" only | "pm", "asb", "rpivid_asb" |
| clocks | none | V3D, PERI_IMAGE, H264, ISP (names "v3d", "peri_image", "h264", "isp") |
| power-domain-cells / reset-cells | 1 / 1 | 1 / 1 |
| system-power-controller | present | present |
| RNG node | `random: rng@7d208000` | `rng@7e104000` |
| RNG compatible | "brcm,bcm2711-rng200" (same string) | "brcm,bcm2711-rng200" |
| RNG reg | 0x7d208000 size 0x28 (physical 0x10_7d208000) | 0x7e104000 size 0x28 |
| RNG other properties | `status` "okay", no interrupts, no clocks | no interrupts, no clocks |

Sources: `ds.dtsi:114-127`; BCM2711 `bcm2711.dtsi:109-128`. The 2712 block
size 0x308 is a different window from the 2711's 0x114, so more registers
are claimed (what they are is **not found** here). The compatible string of
the watchdog is new and has no fallback to the BCM2835 watchdog string, which
suggests the register layout is not guaranteed to match the Pi 4's
(inference; this record does not read the driver). The RNG200 string is the
Pi 4's, so the device is declared identical; only the address window moves.
The tree names the node `watchdog` as an alias for `pm` (`rpi.dtsi:118,174`).
TF-A states the same two bases: power management, reset and watchdog at
0x10_7d200000 and the RNG at 0x10_7d208000 (`TFA:rpi_hw.h`).

## TF-A 2.15.0: the Pi 5 port

- Debug UART: PL011 at 0x10_7d001000 (`RPI_IO_BASE + 0x7d001000`), clock
  44000000 Hz, 115200 baud; the same UART serves crash output
  (`TFA:rpi_hw.h`; `TFA:platform_def.h` PLAT_RPI_UART_BAUDRATE and
  CRASH_UART_BASE). The TF-A document says all boot stages print to the
  "dedicated UART debug port" at 115200 8n1 (`TFA:docs/plat/rpi5.rst`).
- What it says about the BL31 the Pi 5 firmware carries: "There's also a
  custom BL31 TF-A armstub included for PSCI, which can be replaced with this
  port." and the Pi 5 firmware's VPU blobs "have been moved into EEPROM". So
  the firmware carries its own BL31-based arm stub providing PSCI;
  its source and version are **not found**. The port is a minimal BL31 for
  booting 64-bit EL2 payloads and is stated to be not secure: all memory used
  is DRAM and no secure memory controller seems to exist
  (`TFA:docs/plat/rpi5.rst`).
- Replacement: copy the built stub to the boot partition and set
  `armstub=bl31.bin` in config.txt, or name it `armstub8-2712.bin`
  (`TFA:docs/plat/rpi5.rst`). TF-A builds BL31 only, "using the kernel loaded by
  the GPU firmware"; all CPUs enter the stub; reset goes straight to BL31
  (`TFA:platform.mk`).
- BL31 loads at 0x1000, limit 0x80000, maximum size 0x80000
  (`TFA:platform_def.h`). The stub header lives in a 4096-byte region at 0
  (`TFA:plat.ld.S`). Cortex-A76 errata workarounds for 1946160 and 2743102 are
  enabled (`TFA:platform.mk`). Max 4 CPUs in one cluster; the GIC is v2.
- Handoff: the stub header carries the kernel entry and DTB address, which
  the GPU firmware fills in; if the stub magic is wrong the port falls back to
  kernel address 0x80000 (a TF-A default, not the firmware's) and an unknown
  DTB. The 64-bit kernel gets the DTB physical address in x0 and zero in x1-x3
  (`TFA:rpi4_bl31_setup.c:68-92,159-163`). Entry is at EL2 (stated for
  payloads in the document).
- The preloaded DTB base and BL33 base are build options of TF-A, not
  fixed by hardware; setting them may require `kernel_address` or
  `device_tree_address` in config.txt (`TFA:docs/plat/rpi5.rst`).
- File names per TF-A's document: the VPU preloads `kernel_2712.img` or
  `kernel8.img`, overridable with `kernel=`; load addresses are chosen by the
  VPU and changed with `kernel_address=` and `device_tree_address=`.

## Raspberry Pi documentation: boot files and loading

- `os_check`: on the Pi 5 the firmware checks that the partition holds a
  compatible Device Tree file before booting from it, because older kernels
  would be loaded and hang; set `os_check=0` in config.txt to disable the
  check, for example for bare-metal development. Default 1
  (`DOC:config_txt_boot.adoc:304-310`). What exactly counts as "compatible"
  (file name, compatible string) is **not found**.
- Kernel image name: the firmware for the Pi 5, 500, 500+ and CM5 loads
  `kernel_2712.img` by default; if absent it loads `kernel8.img`
  (`DOC:config_txt_boot.adoc:24`). The `kernel=` option overrides the name
  (`config_txt_boot.adoc:22`; for 64-bit kernels it is used instead of the
  automatic choice, line 30). The Pi 5 supports only the 64-bit kernel
  (line 55). A `config.txt` file must exist for the partition to be bootable
  (line 137). The Arm stub defaults to one stored in the firmware; `armstub=`
  names a replacement on the boot partition (line 59).
- Where it loads: the Pi 5-specific page does not state the address. The
  legacy page says 64-bit kernels load at 0x200000 by default (0x8000 for
  32-bit; 0x0 if `kernel_old` is set) and that `kernel_address` changes it
  (`DOC:legacy_config_txt_boot.adoc:38-44`). That page is marked legacy and
  is not Pi 5 specific; whether the Pi 5 firmware uses 0x200000 is therefore
  **unverified** and needs a probe (TF-A's fallback 0x80000 above is only
  its default when the stub header is invalid). `device_tree_address`
  is **not found** in the documentation read (only in TF-A's document).
- The 16K page-size note on `kernel_2712.img` shows the Pi 5 firmware's
  kernel is expected to be built for 16 KiB pages (`config_txt_boot.adoc:24`);
  whether the firmware requires it is **not found**.

## Surprises

- `rp1.dtsi` has no license line; the compiled Pi 5 tree cannot be shown
  permissive from these files (F7).
- No `simple-framebuffer` is defined anywhere; display must come from the
  firmware's allocation or a probe of the passed-on tree (F7).
- The tree's debug UART clock (9.216 MHz) disagrees with TF-A's 44 MHz.
- The BCM2712 watchdog compatible has no BCM2835 fallback and a 0x308-byte
  window, unlike the Pi 4's; only the RNG200 string is unchanged (F8).
- The SD card's 1.8 V switch, power enable and card detect are three lines
  of the always-on GPIO bank, together with the ACT LED, so SD bring-up needs
  that GPIO bank (F6, F7).

## Facts only a board settles

The UART's real input clock; whether the firmware adds or rewrites
`/chosen` nodes (stdout-path, a framebuffer); the default kernel load and DTB
addresses on the Pi 5; the passed-on tree's content; the watchdog register
layout at 0x7d200000; SD DMA behavior and maximum clock.
