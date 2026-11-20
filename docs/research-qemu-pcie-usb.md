# QEMU `virt`: PCIe host bridge, MSI frame and `qemu-xhci`: facts record

A point-in-time research record, written on 2026-11-19 on the Apple
Silicon macOS 27.0.1 development host (Darwin 27.0.0, arm64). It records
what the QEMU binary reports about itself, run as a black box: no QEMU
source was read for it. It answers the QEMU probes that
[design-usb.md](design-usb.md#qemu-suites) lists (probe 3 in part, probe 4
in part) and the PCIe design's question about the MSI frame's range
([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)). A value is
re-checked by running the commands again, never edited in place.

## Method

* QEMU 11.1.3, `/opt/homebrew/bin/qemu-system-aarch64`. The harness
  (`tools/lib/erx/qemu.rb`, `MACHINES['qemu-virt']`) starts `qemu-system-aarch64`
  by name from `PATH` and pins no build of its own, so this is the binary
  it runs on this host.
* The harness's machine options for `qemu-virt`: `-machine
  virt-11.1,gic-version=3`, with `,msi=gicv2m` added under TCG; `-cpu
  host` under HVF and `-cpu cortex-a76` under TCG. These were used, with
  `-m 512 -smp 2`.
* Device tree: `-machine MACHINE,dumpdtb=FILE -accel ACCEL -cpu CPU -m 512
  -smp 2 -nographic -no-reboot`, standard input closed, output in a log,
  under `gtimeout -k 10 30`, decoded with `dtc -I dtb -O dts`. Run for
  `gic-version=3` under HVF, under TCG with `msi=gicv2m`, under TCG
  without `msi`, and `gic-version=2` under TCG.
* Devices: the same command line with `-S` (paused, no guest), `-nic none`,
  `-qmp unix:SOCKET,server=on,wait=off`, `-device qemu-xhci -device
  usb-kbd -device usb-tablet`, under `gtimeout -k 10 60`. A script sent
  QMP `qmp_capabilities`, `query-pci`, `device-list-properties`, `qom-list`,
  `qom-get` and, through `human-monitor-command`, `info pci`, `info usb`,
  `info qtree`, `info mtree` and `xp` (physical memory reads, which also
  reach the PCI configuration space through the bridge's ECAM window).
  Every QEMU was ended by `quit` and none was left running.
* A guest was not run, so what only a guest's reads of the controller's
  BAR can show is under [not settled](#not-settled).

## The MSI frame

Probe 4, first half: the frame's range.

Under HVF with `gic-version=3`, and under TCG with `gic-version=3,msi=gicv2m`,
the tree's `intc` node has the frame as a child:

```
intc@8000000 {
	reg = <0x00 0x8000000 0x00 0x10000 0x00 0x80a0000 0x00 0xf60000>;
	compatible = "arm,gic-v3";
	...
	v2m@8020000 {
		reg = <0x00 0x8020000 0x00 0x1000>;
		msi-controller;
		compatible = "arm,gic-v2m-frame";
	};
};
```

So the frame is at `0x08020000`, 4 KiB. The tree carries no base-line or
line-count property, so the range is the frame's own `MSI_TYPER`, which
was read with `xp /1wx 0x8020008` on the paused machine:

| Variant | `MSI_TYPER` (offset `0x008`) |
| --- | --- |
| HVF, `gic-version=3` | `0x00500040` |
| TCG, `gic-version=3,msi=gicv2m` | `0x00500040` |
| TCG, `gic-version=2` | `0x00500040` |

The register's fields, as the GICv2m frame defines them (design-platforms.md
[MSI frames](design-platforms.md#msi-frames): first line and count): the first
line is bits 25:16 = `0x50` = 80 and the count is bits 9:0 = `0x40` = 64,
so the frame serves interrupt ids 80 to 143, which is SPI numbers 48 to 111.
That agrees with the "SPIs from 48" of
[research-kernel-bases.md](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf).
Whether the field is an interrupt id or an SPI number is the architecture's
definition and was not checked against a document in this task; the
agreement with the earlier record favors the interrupt id.

`info mtree` shows the frame as `0000000008020000-0000000008020fff (prio 0, i/o): gicv2m`
beside `gicv3_dist` at `0x08000000` and `gicv3_redist_region[0]` at
`0x080a0000..0x080dffff`.

The harness does not get an ITS: under TCG with `gic-version=3` and no
`msi` option the frame is replaced by

```
its@8080000 {
	reg = <0x00 0x8080000 0x00 0x20000>;
	#msi-cells = <0x01>;
	msi-controller;
	compatible = "arm,gic-v3-its";
};
```

which is why the harness adds `msi=gicv2m` under TCG. With `gic-version=2`
under TCG the frame is the same node at the same address (the GIC is `arm,cortex-a15-gic`,
distributor `0x08000000`, CPU interface `0x08010000`); HVF refuses it:
`qemu-system-aarch64: HVF does not support GICv2 emulation`. The harness uses
GICv3 under both accelerators, so the frame is `0x08020000`, lines 80 to 143.

## The PCIe host bridge

The tree's `pcie@10000000` node is the same for HVF and TCG and for GICv2
and GICv3:

```
pcie@10000000 {
	interrupt-map-mask = <0x1800 0x00 0x00 0x07>;
	#interrupt-cells = <0x01>;
	ranges = <0x1000000 0x00 0x00 0x00 0x3eff0000 0x00 0x10000
	          0x2000000 0x00 0x10000000 0x00 0x10000000 0x00 0x2eff0000
	          0x3000000 0x80 0x00 0x80 0x00 0x80 0x00>;
	reg = <0x40 0x10000000 0x00 0x10000000>;
	msi-map = <0x00 0x8004 0x00 0x10000>;
	dma-coherent;
	bus-range = <0x00 0xff>;
	#size-cells = <0x02>;
	#address-cells = <0x03>;
	device_type = "pci";
	compatible = "pci-host-ecam-generic";
};
```

| Item | CPU address | Size |
| --- | --- | --- |
| ECAM (`reg`) | `0x4010000000` | `0x10000000` (256 MiB) |
| I/O window (`0x1000000`) | `0x3eff0000` (PCI I/O address 0) | `0x10000` |
| 32-bit memory window (`0x2000000`) | `0x10000000` (PCI address `0x10000000`) | `0x2eff0000`, to `0x3effffff` |
| 64-bit memory window (`0x3000000`) | `0x8000000000` (PCI address `0x8000000000`) | `0x8000000000` (512 GiB) |
| Bus range | buses 0 to 255 | |

`info mtree` shows `gpex_ioport_window` at `0x3eff0000-0x3effffff`. The
`msi-map` sends every requester id from 0 for `0x10000` to the frame's phandle
(`0x8004`, the `v2m` node, or the `its` node of the ITS variant). INTx lines
go to the GIC's SPI numbers 3 to 6 (level, `0x04`): pin `p` (1 to 4) of
slot `s` is SPI `3 + ((p - 1 + s) mod 4)`.

## `qemu-xhci`

With `-nic none -device qemu-xhci -device usb-kbd -device usb-tablet`
(without `-nic none` QEMU also adds a `virtio-net-pci` at slot 1 and the
controller is at slot 2).

Identity, from `info pci` and the configuration space read through ECAM
(`xp /64wx 0x4010008000`, bus 0 slot 1 function 0, offset `0x8000` per slot):

| Item | Value |
| --- | --- |
| Vendor, device | `1b36:000d` |
| Subsystem | `1af4:1100` |
| Class, subclass, programming interface, revision | `0x0c`, `0x03`, `0x30` (xHCI), `0x01` |
| Header type | `0` (offset `0x0c` is `0x00000000`) |
| BAR0 | `0x00000004` as written by QEMU: 64-bit memory, not prefetchable, size 16384 (`0x4000`), not mapped (address `-1`) |
| BAR1 to BAR5 | none: BAR1 is BAR0's upper half, BAR2 to BAR5 read zero |
| Interrupt pin, line | pin A, line 0 |
| Capability pointer | `0x90` |
| Capabilities | `0x90` MSI-X (id `0x11`), `0xa0` PCI Express (id `0x10`) |

The raw capability words:

```
0x90: 0x000fa011   id 0x11 (MSI-X), next 0xa0, message control 0x000f: table size 16, disabled
0x94: 0x00003000   table in BAR0 at 0x3000
0x98: 0x00003800   pending bit array in BAR0 at 0x3800
0xa0: 0x00920010   id 0x10 (PCI Express), next 0x00, capabilities 0x0092: version 2, port type 9
```

There is no MSI capability (id `0x05`) in the list. The device's `msi` and
`msix` properties are `auto`; `qom-get` on the device reads `msi` as `"off"`
and `msix` as `"auto"`, and `device-list-properties qemu-xhci` lists both with
default `auto`. So with default properties the controller offers 16 MSI-X
vectors, in BAR0, and no MSI. (design-usb.md and design-pcie.md say "MSI and
MSI-X"; `msi=on` was not tried.) The word at `0x60` is `0x00000030`,
the serial bus release number byte, USB 3.0.

Ports: `device-list-properties` gives `p2` and `p3`, both `uint32` with default 4,
and `qom-get` reads 4 and 4: four USB 2 and four USB 3 ports. `info usb`:

```
  Device 0.0, Port 1, Speed 480 Mb/s, Product QEMU USB Keyboard
  Device 0.0, Port 2, Speed 480 Mb/s, Product QEMU USB Tablet
```

`info qtree` shows the controller with `bus: usb-bus.0`, `msi = "off"`,
`msix = "auto"`, `bar 0: mem at 0xffffffffffffffff [0x3ffe]`, and the two
devices as `usb_version = 2`. Its other properties are `streams` (default
true) and `conditional-intr-mapping` (default false); no `intrs` or `slots`
property exists on the device (`qom-get` refuses both).

### `query-pci` field names

`query-pci` returns a list of buses and each device's raw numbers in decimal,
for the controller:

```
[{"bus":0,"devices":[
 {"irq_pin":0,"bus":0,"qdev_id":"","slot":0,"class_info":{"class":1536,"desc":"Host bridge"},
  "id":{"device":8,"subsystem-vendor":6900,"vendor":6966,"subsystem":4352},"function":0,"regions":[]},
 {"irq_pin":1,"bus":0,"qdev_id":"","irq":0,"slot":1,"class_info":{"class":3075,"desc":"USB controller"},
  "id":{"device":13,"subsystem-vendor":6900,"vendor":6966,"subsystem":4352},"function":0,
  "regions":[{"prefetch":false,"mem_type_64":true,"bar":0,"size":16384,"address":-1,"type":"memory"}]}]}]
```

Bus: `bus`, `devices`. Device: `bus`, `slot`, `function`, `class_info`
(`class`, `desc`), `id` (`vendor`, `device`, `subsystem-vendor`, `subsystem`),
`irq_pin`, `qdev_id`, and `irq` (absent on the host bridge), `regions`. Region:
`bar`, `type` (`"memory"` or `"io"`), `address` (`-1` while unmapped), `size`,
and for `"memory"` also `prefetch` and `mem_type_64`. The class value `3075`
is `0x0c03`, the vendor `6966` is `0x1b36`. A BAR's number is its register
index, so a 64-bit BAR at 0 skips BAR 1; the capability lists, the MSI-X
table location and the programming interface are not in `query-pci`, which is
why the configuration space was read through ECAM.

## Probe numbering

The USB design cites two QEMU probes by number: probe 3 at the
controller's capability registers ("records them in the facts record
(probe 3)"), and probe 4 at its MSI frame paragraph: "the frame's range on QEMU
`virt`, and whether Fiasco binds its lines with the edge trigger an MSI needs,
are probe 4". The PCIe design's "probe 4" (the frame's range, and "whether the
fork's interrupt controller honours the mode for these lines" as its second
half) is the same probe. So probe 3 is the controller's capability registers
and port layout, and probe 4 is the MSI frame: its range of lines (settled
above), Fiasco binding a line edge-triggered, and an MSI from `qemu-xhci`
arriving on it.

## Not settled

* The xHCI capability registers (`CAPLENGTH`, `HCSPARAMS1` to `3`, `HCCPARAMS1`,
  the doorbell and runtime offsets): the BAR is not mapped without a guest,
  and no QEMU monitor command writes the configuration space. Probe 3 stays
  open for a guest read; the port counts above (`p2`, `p3`) are what QEMU
  reports as properties, not read from `HCSPARAMS1`.
* Probe 4's second half, Fiasco binding a frame line edge-triggered, and an
  MSI from `qemu-xhci` arriving on it: both need a guest on Fiasco.
* Hotplug and its port events, the IOMMU stream, the `pcap` reference and
  `usb-redir`: not probed here.
