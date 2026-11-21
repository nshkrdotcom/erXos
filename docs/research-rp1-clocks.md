# RP1 clocks, pads and resets for Ethernet and USB: facts record (clean room)

A point-in-time research record, written on 2026-11-21 on the Apple Silicon
macOS development host whose scratch directory holds the sources below. It
states what is needed to bring up RP1's Gigabit Ethernet MAC and its two USB
hosts without Linux: the clock bank, the PLLs, what Linux programs, the pad
and function-select setup, and the reset story. Design and code agents read
this record, never the Linux sources. It contains no code and no copied
comments; register and field names are hardware facts.

Statements marked **found** are read from the cited source. **inferred** is my
arithmetic or reading of a name. **not found** means the sources read do not
say.

## Sources

Scratch directory: `/Users/stas/erxos-scratch/sources/`. All hashes rechecked
on 2026-11-21.

| Short name | File | SHA-256 |
|---|---|---|
| PDF | `pi5/rp1/rp1-peripherals.pdf` (RP1 Peripherals, Raspberry Pi) | `87fb7b24e8d9add075b849d095a107827610c0409ea194785af624c1ea986c3d` |
| PDFTXT | `pi5/rp1/rp1.txt` (text of the PDF; line numbers cited) | `4861893b9ab3bd00e7692424baa5bdd1b876f6266a76346c9ba774d8ffca8d0f` |
| clk-rp1.c | `pi5-linux-rp1/drivers_clk_clk-rp1.c` | `52e48eca35f0127e689798a0e24143f455bcc068ea285015b0c0775424a0a96e` |
| rp1.dtsi | `pi5-linux-rp1/arch_arm64_boot_dts_broadcom_rp1.dtsi` | `ab3fe239e9a62742d035187ec50f65ec769cff002788f0e12b2afcad0bbaf460` |
| pi5b.dts | `pi5-linux-rp1/arch_arm64_boot_dts_broadcom_bcm2712-rpi-5-b.dts` | `f27bea575be85d9e0bbef3a1337961f12143cd7487079ee33d92c2f2c4d45df6` |
| rpi.dtsi | `pi5-linux-rp1/arch_arm64_boot_dts_broadcom_bcm2712-rpi.dtsi` | `874963e6586489a6cad16c148499dc93eb77de5f8ce26e37cda7e5e2f37dd7f7` |
| mfd rp1.c | `pi5-linux-rp1/drivers_mfd_rp1.c` | `a968264abbbe463368b72e0087393d5ab3f0365b20738838d5be55c03d9bb658` |
| macb_main.c | `pi5-linux-rp1/drivers_net_ethernet_cadence_macb_main.c` | `c3d9a9d79e48b9517424a1c472f34fcd7e954da09a238935116f1358648d5082` |
| pinctrl-rp1.c | `pi5-linux-rp1-pinctrl/pinctrl-rp1.c` | `6a2ba6fac01f2938fbf3e288cad88eb512961abc98fdbc2a3df74bd128d81867` |

The Linux files are Raspberry Pi's tree `github.com/raspberrypi/linux`, branch
rpi-6.12.y at commit `dcc3a57b713fe33c33a9eba7e0704bc87aed6698`, fetched over
HTTPS from raw.githubusercontent.com at that commit. `pinctrl-rp1.c` is
`drivers/pinctrl/pinctrl-rp1.c` of the same commit, fetched on 2026-11-21 into
`pi5-linux-rp1-pinctrl/`. Nothing was run. The other files are named by the
directory's flattened paths (underscores for slashes).

## 1. Where things live

All offsets are from RP1's BAR 1 (the 0x4000_0000 peripheral window, the
addresses the PDF uses). The PDF lists them in its address maps (PDFTXT:375-379,
381-383, 497, 531, 537-545, 557-559).

| Block | Address | Note |
|---|---|---|
| resets | 0x40014000 | listed; registers not documented (see section 7) |
| clocks_main | 0x40018000 | APB, atomic aliases supported |
| clocks_video | 0x4001c000 | |
| pll_sys | 0x40020000 | = clocks_main + 0x8000 |
| pll_audio | 0x40024000 | = clocks_main + 0xc000 |
| eth (Cadence GEM) | 0x40100000 | PDFTXT:5658; dtsi gives size 0x4000 |
| eth_cfg | 0x40104000 | APB, atomic aliases supported |
| xosc | 0x40150000 | |
| usbhost0_cfg / usbhost1_cfg | 0x40160000 / 0x40164000 | |
| vbusctrl | 0x40170000 | |
| usbhost0 / usbhost1 | 0x40200000 / 0x40300000 | 1 MiB each, AXI |
| io_bank0/1/2 | 0x400d0000 / 0x400d4000 / 0x400d8000 | |
| pads_bank0/1/2 | 0x400f0000 / 0x400f4000 / 0x400f8000 | |

**found**: rp1.dtsi:24-28 places the clock controller at 0x40018000 with a
length of 0x10038 and one parent, a fixed 50 MHz crystal clock
(rp1.dtsi:1248-1253). The driver's register names (clk-rp1.c:27-170) are
offsets from that base, and the PLL registers sit at 0x8000 (system PLL) and
0xc000 (audio PLL) and 0x10000 (video PLL) within the same region, which agrees
with the PDF's pll_sys address (inferred from the arithmetic: 0x40018000 +
0x8000 = 0x40020000).

## 2. The clock tree RP1 gives Ethernet and USB (found)

PDF 2.5 (PDFTXT:593-650): the reference is a 50 MHz crystal, chosen to meet the
PHY needs of USB, Ethernet, PCIe and MIPI. Three internal PLLs: core (system
clocks), audio, video. The PCIe, USB3, USB2 and DSI interfaces carry their own
embedded PLLs. The core clock (clk_sys) typically runs at 200 MHz with the
core PLL's VCO at 2 GHz (PDF text; but see the next section: Linux sets 1 GHz).
The RGMII clock is 125 MHz, generated from the core PLL. Figure 3 (the clock
diagram) is an image and is not in the text.

The clocks the Ethernet MAC takes, in Linux's device tree (rp1.dtsi:999-1014):
four clocks named pclk, hclk, tsu_clk and tx_clk. pclk and hclk are both
clk_sys. tsu_clk is clk_eth_tsu. tx_clk is clk_eth. The PHY mode is RGMII with
internal delays (phy-mode rgmii-id).

The USB hosts: the two dwc3 nodes (rp1.dtsi:1118-1152) have **no clocks
property** at all.

### Clock building blocks (clk-rp1.c)

Every gateable clock is three registers: CTRL, DIV_INT (and DIV_FRAC for a few,
none of the clocks here) and SEL.

- CTRL bit 11 is ENABLE (clk-rp1.c:240). CTRL bits 9:5 select the auxiliary
  source (mask 0x3e0, clk-rp1.c:241-242). CTRL low bits select the source
  among the "standard" sources; the mask differs by clock (3 for clk_sys, 1
  for clk_slow_sys). Source value 1 selects the auxiliary list (AUX_SEL = 1,
  clk-rp1.c:181; read in the get-parent routine at 1101-1134 and the
  set-parent routine at 1136-1171).
- The divider is the integer in DIV_INT. A value of 0 means 2^16 (clk-rp1.c:
  1006-1031). The output is the source divided by DIV_INT. The maximum is 8
  bits for most clocks, 24 bits for clk_sys (clk-rp1.c:199-201).
- SEL is one-hot and reads back which source is actually selected; zero means
  the switch has not completed or the source is not running (clk-rp1.c:1101-
  1134).
- Enabling a clock is a read-modify-write that sets CTRL bit 11
  (clk-rp1.c:1033-1052). Setting a rate writes DIV_INT then sets the source
  field (clk-rp1.c:1173-1206). The driver does not poll SEL after changing the
  source in the code read (**not found**: any required wait).

### Register offsets from the clocks_main base (clk-rp1.c, cited lines)

| Register | Offset | Line |
|---|---|---|
| CLK_SYS_CTRL / DIV_INT / SEL | 0x14 / 0x18 / 0x20 | 47-49 |
| CLK_SLOW_SYS_CTRL / DIV_INT / SEL | 0x24 / 0x28 / 0x30 | 53-55 |
| CLK_ETH_CTRL / DIV_INT / SEL | 0x64 / 0x68 / 0x70 | 65-67 |
| CLK_ETH_TSU_CTRL / DIV_INT / SEL | 0x134 / 0x138 / 0x140 | 119-121 |
| CLK_USBH0_MICROFRAME CTRL / DIV_INT / SEL | 0xf4 / 0xf8 / 0x100 | 103-105 |
| CLK_USBH1_MICROFRAME CTRL / DIV_INT / SEL | 0x104 / 0x108 / 0x110 | 107-109 |
| CLK_USBH0_SUSPEND CTRL / DIV_INT / SEL | 0x114 / 0x118 / 0x120 | 111-113 |
| CLK_USBH1_SUSPEND CTRL / DIV_INT / SEL | 0x124 / 0x128 / 0x130 | 115-117 |
| PLL_SYS CS / PWR / FBDIV_INT / FBDIV_FRAC / PRIM / SEC | 0x8000 / 0x8004 / 0x8008 / 0x800c / 0x8010 / 0x8014 | 27-32 |
| PLL_AUDIO same six, plus TERN at 0xc018 | 0xc000.. | 33-39 |
| PLL_VIDEO same six | 0x10000.. | 40-45 |
| frequency counter FC0 (REF_KHZ .. RESULT) | 0x21c .. 0x238 | 169-176 |

(Clock-bank offsets for the video clocks start at 0x4000 within the bank,
clk-rp1.c:183-198; not needed for Ethernet or USB.)

### clk_sys

Parents: the crystal (source 0), nothing (source 1), the system PLL's primary
output (source 2). Maximum 200 MHz, 24-bit integer divider, flagged critical
because it is "always enabled in hardware" (clk-rp1.c:1846-1861). It clocks
both the MAC's pclk and hclk. Linux assigns it 200 MHz (rp1.dtsi:46-58).

### clk_slow_sys

Parent: the crystal only. Maximum 50 MHz, 8-bit divider, also critical,
always enabled in hardware (clk-rp1.c:1862-1878). Linux assigns 50 MHz and the
dtsi comment says it must match the crystal frequency and is used as the
reference of the frequency counter FC0 (rp1.dtsi:40-41, 54;
clk-rp1.c:254).

### clk_eth (the MAC's tx_clk, 125 MHz)

Auxiliary sources only, nine, in this order (aux index 0 first; clk-rp1.c:
1920-1939): pll_sys_sec, pll_sys, pll_video_sec, and the six GPIO clock
sources gp0 to gp5. Maximum 125 MHz, 8-bit integer divider, no fractional
divider. Linux assigns it 125 MHz (rp1.dtsi:50). Not flagged critical.

**inferred**: with the system PLL's secondary divider at 8 (see below), 1 GHz
divided by 8 is 125 MHz, so clk_eth takes aux source 0 (pll_sys_sec) with
DIV_INT 1. Linux's rate-selection code (clk-rp1.c:1267-1337) chooses the
parent; I did not trace which parent it picks for 125 MHz. The tree on a running
Pi 5 would settle which one is selected at boot.

### clk_eth_tsu (the 1588 timestamp clock, 50 MHz)

Auxiliary sources only, eight: the crystal, pll_video_sec and gp0 to gp5
(clk-rp1.c:2079-2099). Maximum 50 MHz, 8-bit divider. Linux assigns 50 MHz
(rp1.dtsi:55). **inferred**: crystal as source with DIV_INT 1.

### The USB host clocks

The register map has MICROFRAME and SUSPEND clocks for each host (offsets in
the table above), but Linux's clock table does not register them
(**found**: grep of clk-rp1.c for usb and the 0xf4..0x130 registers finds only
the register definitions, lines 103-117; the clock descriptor array has no
entry). The USB hosts' device-tree nodes carry no clocks. **not found**: what
the host needs from clk_sys, those four clocks or the USB PHY PLLs, and
whether firmware or reset defaults enable them. **inferred**: Linux relies on
their reset state or on firmware; the PDF says the USB PHYs have PLLs of their
own (PDFTXT:593-615) and gives no registers for usbhost_cfg (**not found**).

## 3. The PLLs (found)

### Core PLL (pll_sys_core)

Registers: CS, PWR, FBDIV_INT, FBDIV_FRAC (clk-rp1.c:27-30).

- CS bit 31 is LOCK. CS bits from 0 hold the reference divider (REFDIV)
  (clk-rp1.c:216-217).
- PWR bits: 0 PD, 1 DACPD, 2 DSMPD, 3 POSTDIVPD, 4 4PHASEPD, 5 VCOPD; mask
  0x3f (clk-rp1.c:219-225). A cleared PWR register means every part is on.
- The VCO rate is the crystal times (FBDIV_INT plus FBDIV_FRAC as a 24-bit
  fraction) divided by REFDIV (clk-rp1.c:569-595: integer part from the high
  bits and a 24-bit fraction).
- The driver marks the core PLLs critical (clk-rp1.c:1524).
- "Is on" is read as: PWR bit 0 or bit 3 set (clk-rp1.c:511-519). This looks
  inverted relative to the bit names (it reports on when PD is set); I
  record it as read and flag it. **inferred**: a defect or a quirk of the
  driver, not hardware behavior.

Bringing a core PLL on, in order (clk-rp1.c:521-556):

1. If CS LOCK is not set: write PWR to 0x3f (everything powered down), write
   FBDIV_INT 20, FBDIV_FRAC 0, and CS to REFDIV 1. (20 times 50 MHz is 1 GHz.)
2. Write PWR to 0 if FBDIV_FRAC is nonzero, otherwise to DSMPD only (bit 2,
   the delta-sigma modulator bypassed for integer division).
3. Poll CS bit 31 until set, at most 100 ms.

Linux logs an error and returns a failure on a lock timeout. Turning it off
writes PWR to 0 (clk-rp1.c:558-567), which is a notable fact: PWR 0 powers
everything on in the bit names, so the off-write appears to match the "is on"
reading above, i.e. in this register set a set bit means "on". **found but
ambiguous**; the PDF's PLL registers are not in the text (**not found**: PDF
register tables for PLL_SYS).

### Primary and secondary outputs

- PLL_SYS_PRIM (0x8010): DIV1 in bits 18:16 (mask 0x70000), DIV2 in bits
  14:12 (mask 0x7000). pll_sys output is VCO divided by DIV1 times DIV2
  (clk-rp1.c:207-210, 746-765). Bit 4 PH_EN enables the phase output, bits
  1:0 select the phase (0, 90, 180, 270 degrees); pll_sys_pri_ph is pll_sys
  divided by a fixed 2, phase 0 (clk-rp1.c:231-237, 799-827, 1795-1801).
- PLL_SYS_SEC (0x8014): divider in bits 12:8 (5 bits), reset bit 16
  (PLL_SEC_RST), implementation bit 31 (reads set when the divider exists;
  Linux warns if it is not set when enabling) (clk-rp1.c:212-214, 227-228,
  895-933). To change the divider: set the reset bit with the new value,
  clear the reset bit. The code's comment says ten VCO cycles should pass in
  between and it does not wait. The divider is clamped to 8 to 19.
  Enabling the divider clears the reset bit (clk-rp1.c:904-921).

### What Linux programs (rp1.dtsi:30-58, found)

The clock node's assigned-clocks and assigned-clock-rates, applied by the
clock framework after the provider registers (rates in Hz):

| Clock | Rate | Result (inferred arithmetic) |
|---|---|---|
| pll_sys_core | 1,000,000,000 | VCO 1 GHz (PDF text says 2 GHz; they disagree) |
| pll_audio_core | 1,536,000,000 | |
| pll_sys | 200,000,000 | prim dividers multiply to 5 |
| pll_sys_sec | 125,000,000 | secondary divider 8 |
| clk_eth | 125,000,000 | |
| pll_audio | 61,440,000 | |
| pll_audio_sec | 153,600,000 | |
| clk_sys | 200,000,000 | |
| pll_sys_pri_ph | 100,000,000 | pll_sys / 2 |
| clk_slow_sys | 50,000,000 | |
| clk_sdio_timer | 1,000,000 | |
| clk_sdio_alt_src | 200,000,000 | |
| clk_eth_tsu | 50,000,000 | |

The dtsi comment says the video PLL and its dividers are left to the video
drivers (rp1.dtsi:32).

Which clocks Linux marks critical: the three core PLLs, clk_sys and
clk_slow_sys (clk-rp1.c:1524, 1859, 1875). No other clock carries the flag, so
the others are enabled only when a consumer enables them (the MAC driver
enables pclk, hclk, tx_clk and the timestamp clock at probe, macb_main.c:4235-
4330).

## 4. Does firmware start the clocks? (partly found)

- **found**: the clock driver contains no code that checks whether the PLLs
  were already running as a precondition. Its core-PLL "on" routine checks
  CS LOCK first and only re-initializes the PLL if it is not locked
  (clk-rp1.c:521-556), so it works either way.
- **found**: the RP1 platform driver, before anything else, requires that BAR 1
  be larger than 64 KiB and otherwise fails with "Not initialised - is the
  firmware running?" (mfd rp1.c:260-272). It also asks a reset controller to
  reset the chip first (mfd rp1.c:253-263; see section 7). So firmware
  (the Pi's boot ROM and EEPROM) is what brings the PCIe link up and sizes
  BAR 1; this is the only firmware dependency the Linux sources state.
- **not found**: any statement, in the PDF or the Raspberry Pi documentation
  fetched under `pi5/rpidoc/` (pcie.adoc, boot-eeprom.adoc, bootflow-eeprom.adoc,
  and others), that firmware programs RP1's PLLs or clocks before the OS.
  A grep of those three files for "rp1" finds nothing. So whether the PLLs are
  locked and clk_sys is running when the OS starts is a **probe fact** for a
  board: read clocks_main/PLL_SYS_CS bit 31 and CLK_SYS_SEL at start. The
  safe design is to do what Linux does: lock the PLL if CS LOCK is clear, then
  assign the rates in the table above.

## 5. Ethernet MAC glue (found)

### Registers of eth_cfg (0x40104000), PDF 7.1 (PDFTXT:5658-5823)

| Offset | Name | Facts |
|---|---|---|
| 0x00 | CONTROL | bit 4 MEM_PD memory power-down, reset 0; bit 3 BUSERR_EN, reset 0 (MAC bus errors off by default); bits 2:1 TSU_INC_CTRL; bit 0 TSU_MS |
| 0x04 | STATUS | RO: bit 5 AWLEN_ILLEGAL and bit 4 ARLEN_ILLEGAL (illegal AXI burst over 16 beats; need a block reset); bit 3 RGMII_DUPLEX; bits 2:1 RGMII_SPEED (0 = 10, 1 = 100, 2 = 1000 Mb/s; reset 2); bit 0 RGMII_LINK_STATUS |
| 0x08-0x10 | TSU_TIMER_CNT0..2 | timestamp counter |
| 0x14 | CLKGEN | bit 9 TXCLKDELEN adds delay to rgmii_tx_clk (reset 0); bit 8 DC50 duty-cycle correction for odd divisors; bit 7 ENABLE starts and stops the clock generator cleanly (reset 1); bit 6 KILL stops it asynchronously; bits 5:4 SPEED_FROM_MAC RO; bit 3 SPEED_OVERRIDE_EN uses the speed in bits 1:0 instead of the MAC's (0 = 10M, 1 = 100M (default), 2 = 1000M) |
| 0x18 | CLK2FC | clock to the frequency counter |
| 0x1c-0x28 | INTR, INTE, INTF, INTS | interrupts |

The PDF says the CLKGEN can be changed on the fly. **inferred**: the MAC's TX
clock to the pad is derived on RP1 from clk_eth (125 MHz) by this generator
according to the link speed the MAC reports, so software does not retune
clk_eth per speed. This agrees with Linux: the RP1 MAC configuration sets a
capability flag meaning "the clock changes in hardware", so the speed-based
retuning of tx_clk is skipped (macb_main.c:5192-5199, 540-546; the same
function would otherwise set 2.5, 25 or 125 MHz per speed, macb_main.c:
547-563).

PDF text says the delay can be added to the TX clock in the CLKGEN, and the
device tree says `rgmii-id`: **inferred** that the PHY adds the receive delay
and RP1 or the PHY adds the transmit delay. Which side adds which is **not
found**; the Pi 5 board's PHY (a Broadcom part at MDIO address 1, pi5b.dts:
175-181) needs a board probe.

### MAC properties Linux sets (rp1.dtsi:999-1014)

Compatible "raspberrypi,rp1-gem" with the Cadence "macb" fallback; interrupt
RP1_INT_ETH; AXI write and read pipelining limits of 8 each; the "use AW2B
fill" option; the MAC address is filled in by firmware (the dtsi property is
zero). The RP1 MAC config sets: gigabit available, hardware-changed clock,
jumbo frames (maximum 10240), PTP (1588), DMA burst length 16 (macb_main.c:
5192-5199).

### Pad / PHY facts for Ethernet

- **found**: the dtsi defines **no pin-control group for the RGMII signals**
  (no ethernet pinctrl in rp1.dtsi or pi5b.dts; grep of both files). The PDF
  says the MAC "drives an external Gigabit PHY over an RGMII bus"
  (PDFTXT:183) and the PDF's function table covers only GPIO 0 to 27
  (section 6); the RGMII pads are dedicated pads, not selectable GPIO
  functions. **inferred**: no pad programming is needed for the data and
  clock lines.
- **found**: the PHY's reset is GPIO 32 of RP1, active low, held for 5 ms
  (pi5b.dts:169-173). Linux asserts the line, waits the duration, deasserts,
  then waits the post-reset delay (default not in these sources) before
  probing MDIO (macb_main.c:500-511). Registered PHY: MDIO address 1,
  with power-down enabled, EEE marked broken at 1000T and 100TX, and LED modes
  0 and 8 (pi5b.dts:175-181, Broadcom properties; their register meaning is
  **not found**).
- GPIO 32 function select: see section 6.

## 6. Pads, function select and the GPIO setup (found / not found)

### Register layout (PDF, bank 0; PDFTXT:925-1260, 2066-2200)

- IO_BANK0 at 0x400d0000: for each GPIO n, STATUS at 8n and CTRL at 8n+4;
  INTR at 0x100 and the interrupt registers follow (PDFTXT:925-990).
  CTRL fields: FUNCSEL bits 4:0 (31 means none, reset 0x1f), OUTOVER bits
  13:12, OEOVER bits 15:14, INOVER bits 17:16, IRQ masks bits 27:20 and
  IRQRESET bit 28, IRQOVER bits 31:30 (PDFTXT:1187-1260). OEOVER: 0 =
  from the peripheral, 1 = inverted, 2 = disable output, 3 = enable output.
  OUTOVER: 0 peripheral, 1 inverted, 2 low, 3 high.
- PADS_BANK0 at 0x400f0000: VOLTAGE_SELECT at 0, then GPIO n at 4 + 4n
  (PDFTXT:2066-2200; offsets inferred from the GPIO 0 entry at 0x04 and the
  linux table below). Pad fields: bit 7 OD output disable (reset 1,
  priority over the peripheral), bit 6 IE input enable (reset 0), bits 5:4
  DRIVE (0 = 2 mA, 1 = 4 mA, 2 = 8 mA, 3 = 12 mA; reset 1), bit 3 PUE
  pull-up, bit 2 PDE pull-down (reset varies), bit 1 SCHMITT (reset 1), bit 0
  SLEWFAST (reset 0). The pad voltage is set per bank by VOLTAGE_SELECT
  (PDFTXT:914).
- Banks 1 and 2: from Linux's bank table (pinctrl-rp1.c:291-296): bank 0
  holds GPIO 0-27, bank 1 holds GPIO 28-33 (six pins, IO at 0x400d4000, pads
  at 0x400f4000), bank 2 holds GPIO 34-53 (IO at 0x400d8000, pads at
  0x400f8000). Within a bank the pin index restarts at 0 (**inferred** from
  bank 0 and the table's per-bank register offsets 0x0000, 0x4000, 0x8000
  for the IO block and 0x0004 for the first pad). The Linux driver's own
  constants agree with the PDF for the pad fields (pinctrl-rp1.c:127-143)
  and FUNCSEL (66-67).
- Function select value for each function is its position in the alt list:
  a0 is 0, a1 is 1, ... a5 is the GPIO function, 5 (pinctrl-rp1.c:148-165,
  and RP1_FSEL_GPIO = 5 at the constants near line 98). The PDF's own table
  (PDFTXT:742-800) lists the same a0..a8 layout for GPIO 0 to 27 only.
  **not found** in the PDF: any row for GPIO 28-53.

### The pins this record needs (pinctrl-rp1.c table, lines 510-535)

| GPIO | a0 | a1 | a2 | a3 | a4 | a5 | a6 |
|---|---|---|---|---|---|---|---|
| 32 | sd1 | gpclk3 | i2s2 | spi6 | uart5 | gpio | proc_rio |
| 42 | gpclk5 | uart5 | vbus1 | spi6 | i2s2 | gpio | proc_rio |
| 43 | gpclk4 | uart5 | vbus1 | spi6 | i2s2 | gpio | proc_rio |

- **PHY reset, GPIO 32**: Linux uses it as a plain GPIO output, so FUNCSEL 5
  (a5, GPIO), with the pad output enabled (pad OD clear); the output value
  is driven through the GPIO block (pinctrl-rp1.c: the rio registers at
  offsets 0 output, 4 output-enable, 8 input, constants near line 120; the
  per-bank rio base is 0x0 in the bank table). Active low means drive 0 to
  assert reset. The initial level after boot is not read from the sources
  (**not found**).
- **USB VBUS, GPIO 42 and 43**: the Pi 5 board file selects function
  "vbus1" on both pins, which is FUNCSEL 2 (a2), through a pin group
  applied to the first USB host's node (pi5b.dts:197-201, 692-695). The
  group has no bias or drive properties, so the pads keep reset defaults
  (with the function selected the output direction comes from the
  peripheral, the pad OD bit is reset to 1 and so the pad output stays
  disabled unless the pin-control driver clears it when a function other than
  GPIO is selected; I did not read that path - **not found**; confirm with a
  register read on a running board). The second USB host's node has no pin
  group in the file (pi5b.dts:203-205); on the Pi 5 the two pins serve the
  board's two ports' power switches as VBUS enables for the controller
  named vbus1 (the pin function name; which host drives which pin is **not
  found**).
- Nothing in the PDF documents the vbus1 function or vbusctrl's registers
  (**not found**).

## 7. Resets (not found)

- The PDF address map lists a resets block at 0x40014000 (PDFTXT:375). Its
  register chapter is not in the PDF's text: no RESET_CTRL, no per-block bits
  (grep of the PDF text for "reset" shows only GPIO interrupt-reset bits and
  field reset values). **not found**: the reset bits for the GEM and the USB
  hosts. The PDF mentions that an illegal AXI burst by the Ethernet DMA
  "will need block reset" (PDFTXT:5725-5729), which confirms that a per-block
  reset exists, but not where.
- Linux resets the whole RP1 chip, not blocks: the PCIe probe asks an
  optional reset control to reset it (mfd rp1.c:253-263), implemented by
  the firmware reset service of the SoC (rpi.dtsi:21-24 declares
  "raspberrypi,firmware-reset"; the Pi 5 file includes the firmware reset
  bindings, pi5b.dts:9). So the whole-chip reset is a call to VideoCore
  firmware (the mailbox), not a register write. **not found**: which reset
  number or message; it needs the firmware-reset binding, not read here.
- Neither the MAC driver nor the dwc3 driver in the tree performs a per-block
  reset through a reset line on RP1 (the dtsi nodes for eth and usb carry no
  resets property: rp1.dtsi:999-1014, 1118-1152). The MAC driver's own
  software reset of the Cadence core is a register sequence of the GEM and is
  outside this record.

## 8. Summary and open items

| Fact group | Status |
|---|---|
| Clock bank base and every clk_sys, clk_eth, clk_eth_tsu, PLL_SYS register offset and bit | found (clk-rp1.c) |
| Enable bit, divider rule, source select | found |
| PLL lock bit, power bits, bring-up order | found (PDF has no PLL register tables: not found there) |
| What Linux programs at probe (assigned rates) | found (rp1.dtsi:30-58) |
| Critical clocks | found (clk_sys, clk_slow_sys, core PLLs) |
| USB host clocks | not found (registers exist; Linux never uses them) |
| Firmware starts RP1 clocks | not found; only BAR 1 sizing is a stated firmware dependency |
| RGMII pad programming | none in Linux (inferred dedicated pads) |
| PHY reset GPIO 32 function, GPIO 42/43 vbus1 function | found (FUNCSEL 5, and 2) |
| Block resets for GEM and USB | not found; whole-chip reset is a firmware call |
| eth_cfg registers | found (PDF) |
| usbhost_cfg, vbusctrl registers | not found (no PDF text) |

Surprises:

1. Linux sets the core VCO to 1 GHz; the PDF text says the core VCO is 2 GHz
   (PDFTXT:622-625). The 125 MHz RGMII clock needs secondary divider 8 only at
   1 GHz (inferred); at 2 GHz it would be 16, inside the code's 8..19 range,
   so both work. A board probe should read PLL_SYS_FBDIV_INT.
2. Linux's USB hosts take no clocks from the clock driver, though the clock
   block has four USB clock registers.
3. The "is on" test and the "off" write of the core PLL read as inverted
   against the PWR bit names; do not copy the polarity without a probe.
4. The PDF has no register chapters for the clock block, the PLLs, resets,
   usbhost_cfg or vbusctrl; everything for them here is from Linux.
