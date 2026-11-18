// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The pure parts of site/terminal.js under Node: the boot-log parse that
// finds the system domain's memory for the Corrupt RAM fault, and the fault
// table's groups and availability, and the checked file the boot image is
// kept as. fixtures/boot-160m.log is the serial
// output of a boot on QEMU's virt (1 core, 160 MiB, erx.watchdog=1,30,600)
// up to the root task's first report.
// Run by test/host/site_faults_test.rb.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { parse_system_memory, seeded_numbers, disk_of, fault_availability, end_fault, FAULTS, FAULT_GROUPS, BOOT_LOG_LIMIT,
         virtio_disks, virtio_slots, NET_DEVICE, CheckedFile, serial_lines }
    from "../../site/terminal.js";

const real_log = readFileSync(new URL("fixtures/boot-160m.log", import.meta.url), "latin1");

// A minimal log of the same shape, for the refusals.
const log = ({ ram = "0000000040000000 - 0000000049ffffff", ip = "00000000440bf000",
               regions = ["    [ 41c01000,  41caafff] { 680.0 KiB} Kern   kernel"],
               map = ["[4:RWX:44000000;44500fff]"] } = {}) => [
    `  RAM: ${ram}: 160.0 MiB`,
    `  Roottask config  node: 0   ip:${ip}`,
    "Regions of list 'regions':",
    ...regions,
    "SIGMA0: Dump of all resource maps",
    "RAM:------------------------",
    ...map,
    "IOMEM:----------------------",
    "[0:RW-:0;3fffffff]",
].join("\r\n");

test("the real boot log gives the root task's program range", () => {
    assert.deepEqual(parse_system_memory(real_log),
        { range: { start: 0x44000000, end: 0x44500fff }, entry: 0x440bf000 });
});

test("the minimal log parses like the real one", () => {
    assert.deepEqual(parse_system_memory(log()).range, { start: 0x44000000, end: 0x44500fff });
});

test("a log without the parts is refused with a reason", () => {
    assert.match(parse_system_memory("").reason, /no RAM/);
    assert.match(parse_system_memory(log({ ip: "zz" })).reason, /no root task/);
    assert.match(parse_system_memory(log({ map: [] })).reason, /no root-task memory/);
});

test("only the root task's writable range that holds the entry is taken", () => {
    assert.match(parse_system_memory(log({ map: ["[4:R-X:44000000;44500fff]"] })).reason, /no root-task memory/);
    assert.match(parse_system_memory(log({ map: ["[0:RWX:44000000;44500fff]"] })).reason, /no root-task memory/);
    assert.match(parse_system_memory(log({ ip: "0000000048000000" })).reason, /no root-task memory/);
    // Map lines outside the RAM section are not sigma0's RAM map.
    const iomem_only = log({ map: [] }).replace("[0:RW-:0;3fffffff]", "[4:RWX:44000000;44500fff]");
    assert.match(parse_system_memory(iomem_only).reason, /no root-task memory/);
});

test("a range outside RAM, not whole pages, too large or over the kernel is refused", () => {
    assert.match(parse_system_memory(log({ ram: "0000000040000000 - 0000000043ffffff" })).reason, /outside RAM/);
    assert.match(parse_system_memory(log({ map: ["[4:RWX:44000000;44500ffe]"] })).reason, /whole pages/);
    assert.match(parse_system_memory(log({ map: ["[4:RWX:40000000;47ffffff]"], ip: "0000000040001000" })).reason,
        /too large/);
    const kernel_inside = ["    [ 44100000,  441fffff] { 1.0 MiB} Kern   kernel"];
    assert.match(parse_system_memory(log({ regions: kernel_inside })).reason, /overlaps the kernel/);
    const sigma0_inside = ["    [ 44400000,  444fffff] { 1.0 MiB} Sigma0 sigma0"];
    assert.match(parse_system_memory(log({ regions: sigma0_inside })).reason, /overlaps the kernel/);
});

test("addresses beyond 40 bits or longer than 16 digits are not taken", () => {
    assert.match(parse_system_memory(log({ map: ["[4:RWX:10044000000;10044500fff]"] })).reason, /no root-task memory/);
    assert.match(parse_system_memory(log({ ip: "0000010044000000" })).reason, /no root task/);
    assert.match(parse_system_memory(log({ map: ["[4:RWX:00000000044000000;44500fff]"] })).reason, /no root-task memory/);
});

test("only the first BOOT_LOG_LIMIT characters are read", () => {
    assert.match(parse_system_memory(" ".repeat(BOOT_LOG_LIMIT) + "\n" + log()).reason, /no RAM/);
    assert.ok(parse_system_memory(" ".repeat(BOOT_LOG_LIMIT - log().length - 1) + "\n" + log()).range);
});

test("seeded numbers repeat for a seed and stay below the limit", () => {
    const a = seeded_numbers(7, 64, 1000);
    assert.deepEqual(a, seeded_numbers(7, 64, 1000));
    assert.notDeepEqual(a, seeded_numbers(8, 64, 1000));
    assert.ok(a.every(n => Number.isInteger(n) && n >= 0 && n < 1000));
    assert.deepEqual(seeded_numbers(0, 4, 50), seeded_numbers(1, 4, 50));
});

test("the menu's groups hold each fault once", () => {
    const listed = FAULT_GROUPS.flatMap(group => group.faults);
    assert.deepEqual([...listed].sort(), Object.keys(FAULTS).sort());
    assert.equal(new Set(listed).size, listed.length);
    assert.deepEqual(FAULT_GROUPS.map(group => group.label), ["Devices", "Memory", "Machine"]);
});

test("availability names the reason an entry cannot be offered", () => {
    const memory = parse_system_memory(real_log);
    const none = { disk: false, disk_down: null, line_held: false, memory: null };
    const all = { disk: true, disk_down: null, line_held: false, memory };
    const reason = (name, facts) => fault_availability(FAULTS[name], facts).reason;
    assert.equal(reason("ram_fail", all), "needs a change inside v64");
    assert.equal(reason("clock_jump", all), "erXos has no wall clock yet");
    for(const name of ["controller_failure", "dead_disk", "hung_disk", "irq_storm", "corrupt_disk"]) {
        assert.equal(reason(name, none), "this machine has no disk");
        assert.equal(fault_availability(FAULTS[name], all).enabled, true);
        assert.equal(reason(name, { ...all, disk_down: "the disk is dead already" }), "the disk is dead already");
    }
    assert.equal(reason("controller_failure", { ...all, line_held: true }), "another fault holds the disk's interrupt");
    assert.equal(fault_availability(FAULTS.dead_disk, { ...all, line_held: true }).enabled, true);
    assert.equal(reason("corrupt_ram", none), "waiting for the boot log's memory map");
    assert.match(reason("corrupt_ram", { ...none, memory: parse_system_memory("") }), /no RAM/);
    assert.equal(fault_availability(FAULTS.corrupt_ram, all).enabled, true);
    for(const name of ["power_cut", "cpu_freeze"]) assert.equal(fault_availability(FAULTS[name], none).enabled, true);
});

// A stand-in for the parts of v64 the disk faults touch, as src/arm/cpu.js,
// src/virt/io.js and src/virtio_mmio.js lay them out.
function fake_machine({ disk_bytes = null } = {}) {
    const lines = new Map();
    // v64 reserves owner 0 (src/virt/io.js).
    const ranges = [null];
    const io = {
        ranges,
        register_mmio(base, size, handler) { ranges.push({ base, size, handler }); return ranges.length - 1; },
        unregister_mmio(owner) { ranges[owner] = null; },
    };
    const cpu = { io, virtio_transport: "mmio", virtio_devices: [], virtio_mmio: [], virtio_mmio_slots: [],
                  set_irq(intid, level) { lines.set(intid, level); } };
    const handler = { name: "virtio-mmio" };
    for(let slot = 0; slot < 32; slot++) cpu.virtio_mmio_slots.push(io.register_mmio(0x0a000000 + slot * 0x200, 0x200, handler));
    if(disk_bytes) {
        // update_irq lives on the prototype, as VirtioMmio's does.
        const transport = Object.assign(Object.create({ update_irq() { cpu.set_irq(this.intid, this.isr !== 0); } }),
            { intid: 48 + 31, level: false, isr: 0 });
        cpu.virtio_mmio[31] = transport;
        const buffer = { byteLength: disk_bytes.byteLength,
                         get(start, length, fn) { fn(disk_bytes.subarray(start, start + length)); },
                         set(start, bytes, fn) { disk_bytes.set(bytes, start); fn(); } };
        cpu.virtio_devices.push({ slot: 31, name: "virtio-blk", device: { backend: { buffer } } });
    }
    const emulator = { v86: { cpu } };
    const session = { emulator, repairs: [], applied: new Set() };
    return { cpu, lines, emulator, session, repairs: session.repairs, handler };
}

test("before v64 builds its machine, and without a disk, there is no disk", () => {
    assert.equal(disk_of({}), null);
    assert.equal(disk_of({ v86: {} }), null);
    assert.equal(disk_of(fake_machine().emulator), null);
});

test("dead disk unmaps the disk's window and raises its line; the repair maps it again", () => {
    const { cpu, lines, emulator, session, handler } = fake_machine({ disk_bytes: new Uint8Array(1 << 17) });
    const window_owner = cpu.virtio_mmio_slots[31];
    const note = FAULTS.dead_disk.action({ emulator, repairs: session.repairs });
    assert.match(note, /0xa003e00/);
    assert.match(note, /INTID 79/);
    assert.equal(cpu.io.ranges[window_owner], null);
    assert.equal(lines.get(79), true);
    cpu.virtio_mmio[31].isr = 0;
    cpu.virtio_mmio[31].update_irq();
    assert.equal(lines.get(79), true, "the device no longer moves the line");
    for(const repair of session.repairs.splice(0)) repair();
    const owner = cpu.virtio_mmio_slots[31];
    assert.deepEqual(cpu.io.ranges[owner], { base: 0x0a003e00, size: 0x200, handler });
    assert.equal(lines.get(79), false);
    cpu.virtio_mmio[31].isr = 1;
    cpu.virtio_mmio[31].update_irq();
    assert.equal(lines.get(79), true, "the device moves the line again");
});

test("a controller failure ends by itself: its own repairs run once, unless a power cut ran them", () => {
    const machine = fake_machine({ disk_bytes: new Uint8Array(1 << 17) });
    const { cpu, lines, session, handler } = machine;
    const window_owner = cpu.virtio_mmio_slots[31];
    const other = () => undefined;
    session.repairs.push(other);
    const note = FAULTS.controller_failure.action(machine);
    assert.match(note, /0xa003e00/);
    assert.match(note, /INTID 79/);
    assert.match(note, /answers again in 3 s/);
    assert.equal(cpu.io.ranges[window_owner], null);
    assert.equal(lines.get(79), true);
    session.applied.add("controller_failure");
    const own = session.repairs.slice(1);
    assert.equal(end_fault(session, "controller_failure", own), true);
    assert.deepEqual(session.repairs, [other], "another fault's repair stays for a power cut");
    assert.equal(session.applied.has("controller_failure"), false);
    assert.deepEqual(cpu.io.ranges[cpu.virtio_mmio_slots[31]], { base: 0x0a003e00, size: 0x200, handler });
    assert.equal(lines.get(79), false);
    cpu.virtio_mmio[31].isr = 1;
    cpu.virtio_mmio[31].update_irq();
    assert.equal(lines.get(79), true, "the device moves the line again");
    assert.equal(end_fault(session, "controller_failure", own), false, "a second end does nothing");

    const cut = fake_machine({ disk_bytes: new Uint8Array(1 << 17) });
    FAULTS.controller_failure.action(cut);
    const undo = cut.session.repairs.slice();
    for(const repair of cut.session.repairs.splice(0)) repair();
    const slots = cut.cpu.io.ranges.length;
    assert.equal(end_fault(cut.session, "controller_failure", undo), false);
    assert.equal(cut.cpu.io.ranges.length, slots, "the window is not mapped twice");
});

test("hung disk keeps completions from the line; a storm holds it high", () => {
    const hung = fake_machine({ disk_bytes: new Uint8Array(1 << 17) });
    FAULTS.hung_disk.action(hung);
    hung.cpu.virtio_mmio[31].isr = 1;
    hung.cpu.virtio_mmio[31].update_irq();
    assert.equal(hung.lines.get(79), false, "lowered at the freeze and kept low");
    const storm = fake_machine({ disk_bytes: new Uint8Array(1 << 17) });
    FAULTS.irq_storm.action(storm);
    storm.cpu.virtio_mmio[31].update_irq();
    assert.equal(storm.lines.get(79), true);
});

test("corrupt disk changes eight bytes, all in blocks that hold data", async () => {
    const bytes = new Uint8Array(1 << 20);
    const data_blocks = [0x20000, 0x31000, 0x80000];
    for(const block of data_blocks) bytes.fill(0x5a, block, block + 4096).fill(0x11, block, block + 7);
    bytes.fill(0xff, 0x40000, 0x41000);
    bytes.fill(0x77, 0, 4096);
    const before = bytes.slice();
    const { emulator, session } = fake_machine({ disk_bytes: bytes });
    const note = await FAULTS.corrupt_disk.action({ emulator, session, still_current: () => true });
    const changed = before.reduce((list, byte, i) => (byte !== bytes[i] ? [...list, i] : list), []);
    assert.ok(changed.length >= 1 && changed.length <= 8, `changed ${changed.length}`);
    assert.ok(changed.every(i => data_blocks.some(block => i >= block && i < block + 4096)));
    assert.match(note, /seed \d+/);
});

test("corrupt disk refuses a disk with no data", async () => {
    const { emulator, session } = fake_machine({ disk_bytes: new Uint8Array(1 << 18) });
    await assert.rejects(Promise.resolve().then(() => FAULTS.corrupt_disk.action({ emulator, session, still_current: () => true })), /no data/);
});

test("corrupt RAM flips bits only inside the parsed range", () => {
    const memory = parse_system_memory(log({ map: ["[4:RWX:44000000;44000fff]"], ip: "0000000044000100" }));
    const beyond = parse_system_memory(log({ ram: "0000000040000000 - 00000000bfffffff",
        map: ["[4:RWX:b0000000;b0000fff]"], ip: "00000000b0000100" }));
    assert.throws(() => FAULTS.corrupt_ram.action({ emulator: {}, session: { memory: beyond } }), /outside this machine's RAM/);
    const ram = new Uint8Array(0x3000);
    const base = 0x43fff000;
    const emulator = { read_memory: (pa, n) => ram.slice(pa - base, pa - base + n),
                       write_memory: (blob, pa) => ram.set(blob, pa - base) };
    FAULTS.corrupt_ram.action({ emulator, session: { memory } });
    const flipped = ram.reduce((list, byte, i) => (byte ? [...list, i + base] : list), []);
    assert.ok(flipped.length > 0);
    assert.ok(flipped.every(pa => pa >= 0x44000000 && pa <= 0x44000fff));
});

// The machine's devices against erXos's platform record: v64 places them by
// its own rule (virtio_slots), and the page must make that rule put each on
// the transport the record names, the network device on a page of its own.
const platform = JSON.parse(readFileSync(new URL("../../config/platforms/qemu-virt.json", import.meta.url), "utf8"));
const record = key => platform.units.find(unit => unit.key === key).devices[0];
const page_of = address => Math.floor(address / 4096);

test("the disk and the network device land on the transports the platform record names", () => {
    const disks = virtio_disks({ stand_in: "the disk" });
    const slots = virtio_slots(disks.length);
    const named = ({ base, line }) => ({ base, intid: line });
    const placed = ({ base, intid }) => ({ base, intid });
    assert.deepEqual(placed(slots.disks[0]), named(record("block")));
    assert.deepEqual(placed(slots.net), named(record("net")));
});

test("only the disk's blank fillers share its page, and the network device has its own", () => {
    const disks = virtio_disks({ stand_in: "the disk" });
    const { disks: disk_slots, net } = virtio_slots(disks.length);
    assert.deepEqual(disks[0], { buffer: { stand_in: "the disk" } });
    for(const { buffer, readonly } of disks.slice(1)) {
        assert.equal(readonly, true);
        assert.equal(buffer.byteLength, 512);
    }
    assert.ok(disk_slots.every(({ base }) => page_of(base) === page_of(record("block").base)));
    assert.notEqual(page_of(net.base), page_of(record("block").base));
    // A blank filler must never stand where the record names a device: no
    // recorded device but the disk lies on the disk's page.
    const recorded = platform.units.flatMap(unit => unit.devices);
    assert.deepEqual(recorded.filter(({ base }) => page_of(base) === page_of(record("block").base)),
                     [record("block")]);
});

test("the network device is virtio on v64's fake router, without a CORS proxy", () => {
    assert.deepEqual({ ...NET_DEVICE }, { type: "virtio", relay_url: "fetch" });
});

// The boot image as the page keeps it: the bytes the site published, which
// content() makes into a fresh, checked buffer for each boot.
const image_bytes = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 7 + (i >> 9)) & 0xff);
const sha256_of = bytes => createHash("sha256").update(bytes).digest("hex");
const kept = (bytes, published = gzipSync(bytes)) =>
    new CheckedFile("image", { source: new Blob([published]), gzipped: true, bytes: image_bytes.length,
                               sha256: sha256_of(image_bytes) });

test("the kept image decompresses to the checked bytes, a fresh buffer each time", async () => {
    const image = kept(image_bytes);
    const first = await image.content(), second = await image.content();
    assert.ok(first instanceof ArrayBuffer, "v64 takes a whole ArrayBuffer");
    assert.deepEqual(new Uint8Array(first), image_bytes);
    assert.deepEqual(new Uint8Array(second), image_bytes);
    assert.notEqual(first, second, "a machine Reset starts never shares the buffer of the one it replaced");
});

test("an image published uncompressed is kept and checked the same way", async () => {
    const image = new CheckedFile("image", { source: new Blob([image_bytes]), gzipped: false, bytes: image_bytes.length,
                                             sha256: sha256_of(image_bytes) });
    assert.deepEqual(new Uint8Array(await image.content()), image_bytes);
});

test("a kept image that no longer holds the checked bytes is refused", async () => {
    const other = image_bytes.map(b => b ^ 1);
    await assert.rejects(kept(other).content(), /image download: checksum mismatch/);
    await assert.rejects(kept(image_bytes.subarray(1)).content(), /image download: wrong length/);
    await assert.rejects(kept(new Uint8Array([...image_bytes, 0])).content(), /image download: too long/);
    const torn = gzipSync(image_bytes);
    torn[torn.length - 6] ^= 0xff;
    await assert.rejects(kept(image_bytes, torn).content());
});

test("the serial log hands on whole lines, with the guest's control characters shown as escapes", () => {
    const lines = [];
    const feed = serial_lines(line => lines.push(line));
    for(const byte of Buffer.from("Starting kernel\r\n\x1b[1mbold\x9b\tend\\\xad\nno end yet", "latin1")) feed(byte);
    assert.deepEqual(lines, ["Starting kernel", "\\x1b[1mbold\\x9b\\x09end\\x5c\\xad"]);
});
