# BCM2712 PCIe root complex and MIP: facts record (clean room)

A point-in-time research record, written on 2026-11-21 on the Apple Silicon
macOS 27.0 development host. It is the clean-room half of the Raspberry Pi 5
bring-up: what Raspberry Pi's Linux driver for the BCM2712's PCIe root
complexes and its MSI-X interrupt unit (the MIP) do, and what the Pi 5 device
tree says, written so that the authors of the PCIe design and of erXos's
`erx_pcie_bcm2712` module never read the GPL-licensed sources. It extends
[research-brcmstb-pcie.md](research-brcmstb-pcie.md) (the BCM2711 record):
every register named there and not mentioned here is taken to be the same
(inference, see "Same as BCM2711" below).

This record states hardware facts and observed driver behavior in its own
words. It contains no code, no copied comments and no identifiers from Linux
except register and field names, which are hardware facts.

Citation form: `RPI:file:line` is Raspberry Pi's downstream Linux at the commit
below. Short paths: `brcmstb.c` = drivers/pci/controller/pcie-brcmstb.c,
`mip.c` = drivers/irqchip/irq-bcm2712-mip.c,
`bcm2712.dtsi`, `rpi-5-b.dts` = arch/arm64/boot/dts/broadcom/...
Statements marked **inference** are my reading of a name or arithmetic on cited
values, not something a source states. **Not found** means the sources below
do not say.

## Sources

Fetched over HTTPS on 2026-11-21, read as data, nothing run.

**Raspberry Pi downstream Linux**, branch `rpi-6.18.y`, commit
`ea17ae02ca28483e508b05c7c44190c01a1ef8eb` (the same commit as the BCM2711
record; the branch head on 2026-11-21 had moved on to `dcc3a57b...`, not used),
from `https://raw.githubusercontent.com/raspberrypi/linux/<commit>/<path>`.
`brcmstb.c` was fetched on 2026-11-14 into
`~/erxos-scratch/sources/linux-brcmstb/rpi-ea17ae02/`; the others on
2026-11-21 into `~/erxos-scratch/sources/linux-rpi-bcm2712-ea17ae0/`.

| SHA-256 | path |
|---|---|
| 212ec09ab522c2e7b81638be3db833bb7e3ad62b201a08f9858092f6130ec787 | drivers/pci/controller/pcie-brcmstb.c |
| 5f42422cfd6cb37beffedd4019650f94aaf19dae0360f37c2c750b7c9e676dab | drivers/irqchip/irq-bcm2712-mip.c |
| 528db3391562b79470028ca60fa86e710a27258d52caca407c4d11248ac9ce88 | arch/arm64/boot/dts/broadcom/bcm2712.dtsi |
| 6d09493a2912d8e616d2dbefe49892591023fb7d47ab08c61cb741da4fc681f0 | arch/arm64/boot/dts/broadcom/bcm2712-rpi.dtsi |
| b90fe894f860fac4f99f6be31d7d696bab8c2a5871b2ac1a25a29c3386ba59d3 | arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts |

**Non-GPL, cited first where they speak:**

| SHA-256 | file |
|---|---|
| d4be7bf9a1e29c09c4592176d04cd8bc4ff146d8f38fe03108e738fa5aa1fee3 | `~/erxos-scratch/sources/pi5/rpidoc/boot.adoc` (raspberrypi/documentation, commit `c6a64966af136da21a1e55551c5a395cb6987fce`, 2026-11-13; path as fetched, the `config.txt` boot-options page) |
| 6dfb6ccf4829435f87f7ad91f137cab3eccb1895fff2ca0b8b5cf78be66af7c9 | `~/erxos-scratch/sources/pi5/tfa/rpi_hw.h` (TF-A `plat/rpi`, BSD; commit not recorded in the fetch, so unverified) |
| 87fb7b24e8d9add075b849d095a107827610c0409ea194785af624c1ea986c3d | `~/erxos-scratch/sources/pi5/rp1/rp1-peripherals.pdf` (searched for MSI, not used here) |

The Linux sources say nothing about what the bootloader leaves behind (the
driver always resets and retrains, see F1.4). No non-GPL source for the MIP's
registers exists in the fetched set; the MIP facts come from Linux alone.

## Summary of what the design needs

* The BCM2712 root complex is the same IP family as the BCM2711's with four
  register-offset changes, a different PERST# and bridge-reset mechanism, a
  multi-window inbound map, and extra bus-bridge (UBUS) controls (F1.1-F1.3).
* Link-status bits, config index and data offsets, and outbound window
  registers are the same as on BCM2711 (F1.1).
* RP1 sits behind `pcie2` (4 lanes, block at 0x10_0012_0000). Its MSIs go to
  MIP 0, through a 4 KiB inbound window that maps PCI bus address
  0xff_ffff_f000 onto the MIP's register page (F2.4).
* Linux never skips a step when the link is up; what could be skipped is an
  inference (F1.4). The bootloader's state with `pciex4_reset=0` is documented
  only as "inherit the configuration"; the details are **not found**.

## F1. The BCM2712 root complex

### F1.1 Block locations and offsets that differ from BCM2711

Three root complexes in the device tree, each a 0x9310-byte register block
(RPI:bcm2712.dtsi:445-448, 482-485, 521-524):

| Node | Block base (CPU) | Lanes | Max speed (DT) | Role on the Pi 5 |
|---|---|---|---|---|
| pcie0 | 0x10_0010_0000 | 1 | gen 2 | enabled by the board file only through other overlays; its MSIs use its own internal MSI block (`msi-parent` is itself, RPI:bcm2712.dtsi:466-467) |
| pcie1 | 0x10_0011_0000 | 1 | gen 2 | the external connector ("pciex1" alias, RPI:bcm2712-rpi.dtsi:266); MSIs to MIP 1 (RPI:bcm2712.dtsi:503-504) |
| pcie2 | 0x10_0012_0000 | 4 | gen 2 | RP1 (`rp1_target` label, RPI:rpi-5-b.dts:120-124; "pciex4" alias, RPI:bcm2712-rpi.dtsi:267); MSIs to MIP 0 (RPI:bcm2712.dtsi:542-543) |

Which of the three the board file enables: it sets `status = "okay"` for pcie2
(RPI:rpi-5-b.dts:120-124 and 764-766); pcie1 is enabled by the dtparam
`pciex1` (RPI:bcm2712-rpi.dtsi:234) and its own board entry sets only a
clkreq mode (RPI:rpi-5-b.dts:760-762). pcie0's enabling is **not found**
(its node has `status = "disabled"`, RPI:bcm2712.dtsi:479).

Offsets that differ from the BCM2711 table (compare
[research-brcmstb-pcie.md](research-brcmstb-pcie.md#register-map-used-on-bcm2711-offsets-from-the-block-base)):

| Register | BCM2711 | BCM2712 | Cite |
|---|---|---|---|
| HARD_DEBUG (SERDES_IDDQ bit 27, CLKREQ and refclk-override bits as before) | 0x4204 | **0x4304** | RPI:brcmstb.c:2207-2237 |
| INTR2_CPU base (legacy MSI status) | 0x4300 | **0x4400** (not used: only for a revision below 0x0303, and the Pi 5 routes MSIs elsewhere) | RPI:brcmstb.c:2207-2237, 2554-2560 |
| RGR1_SW_INIT_1 | 0x9210 | 0x9210 (same; but see bridge reset, F1.2) | RPI:brcmstb.c:2231-2237 |
| EXT_CFG_INDEX / EXT_CFG_DATA | 0x9000 / 0x8000 | **same** 0x9000 / 0x8000 | RPI:brcmstb.c:2231-2237 |
| PERST# control | RGR1_SW_INIT_1 bit 0 (1 = asserted) | **MISC_PCIE_CTRL (0x4064) bit 2, "PERSTB": 1 = deasserted, 0 = asserted** | RPI:brcmstb.c:1006-1016, 138, 2255-2262 |
| Bridge reset | RGR1_SW_INIT_1 bit 1 | a reset line in the device tree (`resets` entry named "bridge": `bcm_reset` 42 for pcie0, 43 for pcie1, 44 for pcie2); the register bit is the fallback only when no such line exists | RPI:brcmstb.c:950-974, 2496-2498; RPI:bcm2712.dtsi:464, 501, 540 |
| RGR1 timeout register (two words before RGR1_SW_INIT_1) | exists, set to 4 s for L1SS | **absent** | RPI:brcmstb.c:1560-1571 |

The `bcm_reset` controller is at 0x1_0150_4318 in the dtsi (RPI:bcm2712.dtsi:213);
how it is programmed is **not found** here (a reset controller driver, not read).
The shared RESCAL reset-controller node `pcie_rescal` is at 0x11_9500
(RPI:bcm2712.dtsi:195-196, compatible `brcm,bcm7216-pcie-sata-rescal`); how its
address range relates to the PCIe blocks is **not found**. The driver names
a quirk that avoids shutting the bridge down on BCM2712 because the RESCAL
block is tied to controller 1 and an access with it off can time out or hang
(RPI:brcmstb.c:415-421, 2041, 2261): so **never put pcie1's bridge in reset or
power it down** (taken from the source's stated reason; whether other
controllers' resets are safe is the same quirk's scope, **unknown** otherwise).

Link status, same as BCM2711 (RPI:brcmstb.c:140-144, 899-905): MISC_PCIE_STATUS at 0x4068; PHYLINKUP bit 4, DL_ACTIVE
bit 5, LINK_IN_L23 bit 6, PORT bit 7 (1 = root complex). The link counts as
up only when both bit 4 and bit 5 are set. The root port's PCIe capability
sits at offset 0xac, so LNKSTA is at 0xbe (RPI:brcmstb.c:1846-1848), unchanged.

Config access, same as BCM2711: the root port at bus 0 device 0 is the block's
own registers (offset = register number); for other devices the driver writes
the target's bus/device/function in ECAM layout (register bits zero) into
EXT_CFG_INDEX, then accesses EXT_CFG_DATA + register; with the link down it
refuses non-root access because such an access aborts the CPU
(RPI:brcmstb.c:908-927). The BCM2712 does not use the other chip's variant
that folds the register number into the index.

### F1.2 Inbound windows: many BARs, plus a UBUS remap

On BCM2711 the driver builds one inbound window (BAR2). On BCM2712 it builds
one inbound window per `dma-ranges` entry of the device tree, in order,
starting at BAR1; up to 10 are allowed (`num_inbound_wins` = 10,
RPI:brcmstb.c:2262; the entry-building loop RPI:brcmstb.c:1189-1221, 1233-1234).
Each window must have a power-of-two size (the source says each must stay a
power of two; alignment of the PCI address to the size is **inferred** from the
BCM2711 text at RPI:brcmstb.c:1270-1278, not stated for BCM2712). For each
window n (1-based) the driver writes:

* **BAR register pair.** Low word at `0x402c + 8*(n-1)` for n = 1..3, and at
  `0x40d4 + 8*(n-4)` for n >= 4 (RPI:brcmstb.c:1312-1318, 123-126): bits 4:0 =
  size code, the remaining bits = the PCI (bus) address low word; high word
  (+4) = PCI address bits 63:32 (RPI:brcmstb.c:1339-1348).
* **Size code**: 4 KiB to 32 KiB: log2(size) - 12 + 0x1c (so 4 KiB = 0x1c,
  8 KiB = 0x1d, 16 KiB = 0x1e, 32 KiB = 0x1f); 64 KiB to 64 GiB:
  log2(size) - 15 (64 KiB = 1 ... 4 MiB = 7, 64 GiB = 21); anything else
  encodes 0, which disables the window (RPI:brcmstb.c:509-521).
* **UBUS remap register pair** (BCM2712 only; it translates the window's bus
  address into the CPU-side address it reaches). Low word at
  `0x40ac + 8*(n-1)` for n = 1..3 and `0x410c + 8*(n-4)` for n >= 4: bits
  31:12 = CPU address low bits, bit 0 = ACCESS_EN, set to 1; high word =
  CPU address bits 63:32 (RPI:brcmstb.c:1320-1326, 1356-1364, 179-181).
  Every window needs it (the source's wording: all of BCM2712's BARs need to be
  set).

BCM2712 has no per-memory-controller size fields (SCB_SIZE bits of MISC_CTRL
are not programmed on it: the number of memory controllers is zero, the
SCB loop does not run, RPI:brcmstb.c:1233-1234, 1446-1457) and the
"disable BAR1 default" window used on other chips is not added
(RPI:brcmstb.c:1199-1200).

MISC_CTRL (0x4008) on BCM2712: same bit positions as BCM2711 (SCB_ACCESS_EN
bit 12, CFG_READ_UR_MODE bit 13, RCB_64B_MODE bit 7, RCB_MPS_MODE bit 10,
MAX_BURST_SIZE bits 21:20); the burst value written is 2 (512 bytes) where
BCM2711 writes 0 (128 bytes) (RPI:brcmstb.c:95-100, 1409-1431).

Outbound windows: the same registers as BCM2711 (low and high PCI address at
0x400c+8w / 0x4010+8w, base/limit in MiB at 0x4070+4w, upper bits at
0x4080+8w / 0x4084+8w); four windows maximum; the driver programs one per
memory entry in the device tree's `ranges`, in order
(RPI:brcmstb.c:620-661, 1509-1538).

The Pi 5 device-tree windows for pcie2 (RP1) (RPI:bcm2712.dtsi:521-557):

| Direction | CPU address | PCI (bus) address | Size | Note |
|---|---|---|---|---|
| outbound, 32-bit non-prefetchable | 0x1f_0000_0000 | 0x0 | 0xfffffffc (about 4 GiB) | |
| outbound, 64-bit prefetchable | 0x1c_0000_0000 | 0x4_0000_0000 | 12 GiB | |
| inbound | 0x1f_0000_0000 | 0x0 | 4 MiB | 32-bit; what it reaches is **not stated** (inference: its own outbound region seen from the bus, RP1 reaching its own BAR space) |
| inbound | 0x0 | 0x10_0000_0000 | 64 GiB | prefetchable; DRAM; bus address = CPU address + 0x10_0000_0000 |
| inbound | 0x10_0013_0000 (MIP 0's registers) | 0xff_ffff_f000 | 4 KiB | the MSI doorbell page (F2.4) |

pcie1 differs in the inbound list: the 64 GiB DRAM window (non-prefetchable) and
the 4 KiB doorbell window to MIP 1 at 0x10_0013_1000, no 4 MiB window
(RPI:bcm2712.dtsi:482-519); pcie0 has only the 64 GiB DRAM window and no
doorbell window (RPI:bcm2712.dtsi:445-480).

So the doorbell's inbound window is set exactly like a DRAM window: it is one
`dma-ranges` entry, becomes BAR3 on pcie2 (third entry; BAR2 on pcie1 as the
second entry), and gets a size code of 0x1c (4 KiB) plus a UBUS remap to the
MIP's CPU address (derived from RPI:brcmstb.c:1189-1221, 1328-1366 and the
list above; the BAR numbers are **inference** from the order of the entries).

### F1.3 Post-setup writes specific to BCM2712

After the common setup the driver runs a BCM2712 post-setup step
(RPI:brcmstb.c:1029-1162). In its own terms, it:

1. Writes a refclk-source configuration (accepting a 54 MHz crystal source)
   through the MDIO interface (block's MDIO registers 0x1100/0x1104/0x1108,
   same as BCM2711): MDIO port 0, address register 0x1f set to 0x1600, then
   register/value pairs 0x16=0x50b9, 0x17=0xbda1, 0x18=0x0094, 0x19=0x97b4,
   0x1b=0x5030, 0x1c=0x5030, 0x1e=0x0007; then waits 100-200 microseconds
   (RPI:brcmstb.c:1031-1049). Spread-spectrum clocking is not supported on this
   chip (the NO_SSC quirk, RPI:brcmstb.c:427, 2261, 2483-2484).
2. Sets PL_PHY_CTL_15 (0x184c) bits 7:0 (PM clock period) to 0x12
   (RPI:brcmstb.c:1055-1058; the reason given is the 54 MHz clock's period).
3. In MISC_UBUS_CTRL (0x40a4) sets bit 13 (UBUS_PCIE_REPLY_ERR_DIS) and
   bit 19 (UBUS_PCIE_REPLY_DECERR_DIS), and writes 0xffffffff to
   MISC_AXI_READ_ERROR_DATA (0x4170): a failed read returns all ones instead of
   an AXI error response (RPI:brcmstb.c:1064-1068, 267-269, 300).
4. Writes UBUS timeout (0x40a8) = 0x0b2d0000 and RC config-retry timeout
   (0x405c) = 0x0aba0000, in units of a 750 MHz clock, about 250 ms and about
   240 ms (RPI:brcmstb.c:1070-1082, 271-273).
5. Quality-of-service setup: in MISC_AXI_INTF_CTRL (0x416c) clears bit 7 and
   sets bits 13, 12 and 11; if bit 12 then reads back 0 (chip revision or
   single-lane controller), sets bits 5:0 (max outstanding requests) to 15
   (RPI:brcmstb.c:1092-1109, 292-299). In MISC_CTRL_1 (0x40a0) clears bit 5
   (VDM QoS control). Optional device-tree maps (`brcm,fifo-qos-map`,
   `brcm,vdm-qos-map`) write TC_QUEUE_TO_QOS_MAP (0x4160 - 4x) and
   VDM_PRIORITY_TO_QOS_MAP (0x4164/0x4168) and VDM_CTL registers (0x0a0c,
   0x0a20) (RPI:brcmstb.c:1112-1160). The Pi 5 board file gives pcie2 a VDM map
   and pcie1 a FIFO map (RPI:rpi-5-b.dts:120-129).
   None of this is needed for function; it affects only bus-priority behavior
   (**inference** from the source's descriptions of it as QoS).

Other BCM2712-visible differences: the bridge's common setup also clears
HARD_DEBUG's SERDES_IDDQ bit (mask 0x08000000, same value as BCM2711) at the
new offset 0x4304 and waits 100-200 microseconds (RPI:brcmstb.c:1400-1407);
the class code of the root port is rewritten to 0x060400 (PCI-PCI bridge) in
ID_VAL3 (0x043c) and the endian mode of BAR2 is set little-endian
(RPI:brcmstb.c:1504-1544), both as on BCM2711. The lane count in the root
port's link capability is overridden from the device tree's `num-lanes` when
it differs, with P2_POWERDOWN_ENA_NOSYNC (PHY_CTL_1 0x1804 bit 3) set, and L0s
is hidden when the board asks (RPI:brcmstb.c:1474-1498; pcie2 sets
`aspm-no-l0s`, RPI:rpi-5-b.dts:120-124).

### F1.4 The state the bootloader leaves, and what could be skipped

**Documented (non-GPL, boot.adoc):** by default the Pi 5 firmware resets the
PCIe x4 controller (the one RP1 uses) before starting the operating system;
with `pciex4_reset=0` in `config.txt` the reset is disabled and "operating
system or bare metal code" may inherit the PCIe configuration the bootloader
set up; default 1. The related option `enable_rp1_uart=1` makes firmware
initialize RP1's UART0 at 115200 bps and skip the RP1 reset too (separately
controlled by `pciex4_reset=1`). A custom-firmware flag (bit 0 of
`boot_load_flags`) also resets PCIe, but the page says it does not apply to
the Pi 5 (no `start.elf`) (boot.adoc:155-183).

**Not found:** which registers the bootloader programs (windows, BARs, RP1's
BAR assignments, MIP, link speed), and whether it programs the MIP at all.
The TF-A platform files fetched (`plat/rpi` for the Pi 5) do not touch PCIe
beyond naming the three root-complex block addresses in a macro
(`rpi_hw.h` RPI_PCIE_RC_BASES = I/O base 0x10_0000_0000 + 0x100000, 0x110000,
0x120000, consistent with the dtsi). Nothing in Linux reads or assumes
inherited state: Linux's probe always resets the bridge (reset line, 100-200
microseconds, release), clears IDDQ, programs every window, class code and
post-setup values, then deasserts PERST#, waits 100 ms and polls up to 100 ms
for link up (RPI:brcmstb.c:1368-1407, 1772-1834, 2508-2552). The only cases
where it forces PERST# asserted first are BCM2711's (RPI:brcmstb.c:1384-1391),
a reason that names bootloaders that "may deassert it".

**Inference** (design input, not a source statement): with an inherited
`pciex4_reset=0` link, a keep-only start would (a) read MISC_PCIE_STATUS
(0x4068) and require bits 4 and 5 set and bit 7 set (root-complex mode), and
fail otherwise; (b) read the inbound BAR and UBUS-remap registers to learn the
windows the bootloader left, instead of writing them (the window layout is not
documented, so it may differ from the DT list in F1.2); (c) skip bridge
reset, PERST# toggling, IDDQ clearing, MDIO refclk writes and the 100 ms
wait. Whether the root complex's outbound windows, class code and post-setup values are
already right is not documented, so a keep-only start would also read those
and compare (board probe items 1 and 7 at the end).

### F1.5 Same as BCM2711

Not repeated here, and taken as unchanged because the downstream driver's
BCM2712 path uses the same code, constants and field masks as BCM2711 for: the
root port's config space at block offset 0 and the capability at 0xac;
MISC_PCIE_STATUS / MISC_REVISION positions; outbound window registers; the
MDIO window; ID_VAL3 class code; LINK_CAPABILITY and ROOT_CAP offsets;
EXT_CFG_INDEX/DATA. Whether the *reset values* match is **unknown**; whether
MISC_REVISION's value on BCM2712 passes the 0x0303 MSI threshold is **not
found** (it is read after setup, RPI:brcmstb.c:2546; the internal MSI block is
not used with MIP).

## F2. The MIP (MSI-X interrupt unit)

### F2.1 What it is and where it is

Two instances (RPI:bcm2712.dtsi:562-578), compatible `brcm,bcm2712-mip`, each a
0xc0-byte register block plus a second `reg` entry that is the doorbell's
**bus** address (not an MMIO range to map):

| Node | Register block (CPU) | Doorbell bus address | Serves | GIC SPI range (DT `msi-ranges`) | `brcm,msi-offset` |
|---|---|---|---|---|---|
| mip0 | 0x10_0013_0000 | 0xff_ffff_f000, size 0x1000 | pcie2 (RP1) | SPI 128, 64 vectors | 0 |
| mip1 | 0x10_0013_1000 | 0xff_ffff_f000, size 0x1000 | pcie1 | SPI 247, 8 vectors | 8 |

The parent interrupt controller is the GICv2 (`&gicv2`). The SPI range is
declared as edge-rising in the `msi-ranges` entry (RPI:bcm2712.dtsi:567, 576).

### F2.2 Registers (offsets from the block base)

All offsets are named only; each is a 32-bit register. Registers come in
low/high pairs, low covering vectors 0-31 and high 32-63 (**inference** from
the L/H names and the 64-vector range; the driver writes both).

| Offset | Name | What Linux does with it |
|---|---|---|
| 0x00 | INT_RAISE | defined, never accessed |
| 0x10 | INT_CLEAR | defined, never accessed |
| 0x20 / 0x30 | INT_CFGL_HOST / INT_CFGH_HOST | written all ones at start-up: "edge-triggered" per the driver's own statement; a 1 bit therefore means edge, a 0 bit presumably level (**inference**) |
| 0x40 / 0x50 | INT_MASKL_HOST / MASKH_HOST | written 0 at start-up: all vectors unmasked for the host (0 = unmasked) |
| 0x60 / 0x70 | INT_MASKL_VPU / MASKH_VPU | written all ones: all vectors masked for the VideoCore CPU (1 = masked) |
| 0x80 / 0x90 | INT_STATUSL_HOST / STATUSH_HOST | defined, never read |
| 0xa0 / 0xb0 | INT_STATUSL_VPU / STATUSH_VPU | defined, never read |

(RPI:mip.c:16-27, 188-196.) The driver writes only the six configuration and
mask registers, once, when it starts; it takes no per-interrupt action on the
MIP: interrupt masking, EOI and type setting are all delegated to the parent
GIC (RPI:mip.c:64-69). Whether the status registers latch per vector, and how
INT_RAISE and INT_CLEAR behave, is **not found** (the names suggest a
software-raise and a clear register; **inference**, unverified). Whether
edge-triggered MIP output needs any MIP-side acknowledge is therefore **not
found**; Linux does none, and the GIC SPI is configured edge-rising.

### F2.3 How vectors map to SPIs and message data

* The driver keeps a bitmap of `num_msis` entries (64 or 8) and hands out a
  power-of-two-aligned block of free entries per request (so multiple MSIs of
  a device get consecutive, aligned vectors) (RPI:mip.c:72-77, 85-120).
* hwirq = bitmap index + `brcm,msi-offset`. The GIC SPI number = hwirq + the
  SPI number in `msi-ranges` (RPI:mip.c:98, 103). The SPI is requested
  edge-rising (RPI:mip.c:104, 112).
* The MSI message the device is told to write: address = the doorbell address
  from the second `reg` entry (0xff_ffff_f000), unmodified; data = hwirq (the
  index **including** the offset) (RPI:mip.c:53-60, 220).
* Arithmetic on those rules (**inference**): mip0: data 0..63, SPI 128..191.
  mip1: data 8..15, SPI 255..262, which is **outside** the `msi-ranges`
  declared SPI range 247..254 (247 + 8 = 255): the offset is added once to the
  data and again to the SPI. Whether the hardware raises SPI 247 + data, so
  that mip1 truly uses 255..262, or the device tree's range is simply
  inconsistent, is **not found**; a board probe must settle which SPIs fire
  (see the end). For RP1 (mip0) the offset is 0 so there is no doubt.
* The driver supports multiple-MSI and MSI-X (flags at RPI:mip.c:158-163).
  How the MIP decodes data into a vector number (low 6 bits? the full word?) is
  **not found**; the driver always writes values below 64.

### F2.4 The doorbell and the inbound window

The doorbell address 0xff_ffff_f000 is a PCI **bus** address, the top 4 KiB of
the 64-bit bus space (RPI:mip.c:220; RPI:bcm2712.dtsi:552-556, 513-518). Each
root complex that uses a MIP maps it by one inbound window of 4 KiB: bus
0xff_ffff_f000 to that MIP's CPU-side register page (pcie2 -> 0x10_0013_0000,
pcie1 -> 0x10_0013_1000), set up by the root complex driver as the last
`dma-ranges` entry (F1.2). A device's MSI write to bus address 0xff_ffff_f000
therefore lands in the MIP block of the root complex it sits behind. The two
MIPs share one bus address because each root complex has its own inbound map.
The write's data selects the vector. Which register offset inside the page the
hardware decodes a write at (address bits below 0xfff) is **not found**;
Linux always writes at offset 0 of the page.

Because the doorbell is a bus address (not a CPU address) an MSI frame record
that carries "the doorbell address" must carry 0xff_ffff_f000 as the bus
address, and the CPU address 0x10_0013_0000 only for mapping the MIP's own
registers.

### F2.5 Does the bootloader program it?

**Not found.** Linux programs the MIP's six registers itself at start-up and
never reads them back, so nothing in these sources says what the MIP's state
is at kernel entry, nor whether the bootloader enables RP1's MSI-X or
touches the MIP when `pciex4_reset=0`. Treat the MIP as unprogrammed
(masks and edge configuration to be written by erXos); read the registers
first on a board to learn the reset state.

## Unknowns that only a board probe can settle

1. The state of pcie2's registers at kernel entry with `pciex4_reset=0`:
   MISC_PCIE_STATUS bits 4/5/7, the inbound BAR (0x402c...) and UBUS remap
   (0x40ac...) registers, whether the doorbell window already exists, the link
   speed and width, PERST# (MISC_PCIE_CTRL bit 2).
2. The state of pcie2's registers with the default `pciex4_reset=1` (a
   comparison).
3. The MIP's reset values for all twelve registers, and the effect of writing
   INT_RAISE or INT_CLEAR.
4. Which GIC SPI fires for mip1 (247 + data, or declared range plus offset),
   and, for mip0, that SPI 128 + data fires for data 0..63.
5. Whether the MIP decodes only the low 6 bits of the write data.
6. Whether the RC reset values of MISC_REVISION and the other "same as
   BCM2711" registers match F1.5.
7. The CPU-side window register behavior (outbound) when pcie2 is inherited:
   whether the bootloader's outbound windows equal the device tree's list.
8. The mechanism and safety of the `bcm_reset` bridge reset lines (42/43/44),
   and the RESCAL block's dependence on pcie1 (F1.1).
