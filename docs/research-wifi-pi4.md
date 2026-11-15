# Raspberry Pi 4 Model B WiFi slot: a clean-room facts record from the Linux tree

Date: 2026-11-15. A point-in-time research record. Written by a clean-room facts writer who
read the GPL sources listed below. Design and code agents read this record, not the sources.
Everything here is in the writer's own words: no code, no copied comments, no structure
mirrored from Linux. It answers the facts F1 to F7 of the table in
[design-wifi.md](design-wifi.md#facts-this-design-does-not-have); that table, as it stood on
2026-11-15, is all of the design the writer read. The design cites this record by fact number.

## Sources

Linux, tag `v7.3.4` (stable tree). Fetched over HTTPS from
`https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/PATH?h=v7.3.4`, read as
data, nothing run. Local copies, outside the erXos tree, with a `SHA256SUMS` file:
`~/erxos-scratch/sources/linux-v7.3.4-wifi/`. Paths below are relative to that directory;
`DT` stands for `arch/arm/boot/dts/broadcom/`, `MMC` for `drivers/mmc/`, `FMAC` for
`drivers/net/wireless/broadcom/brcm80211/brcmfmac/`. Line numbers are those of these copies.

The 64-bit board file `arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dts` is only a one-line
include of the 32-bit tree's file of the same name, so the facts come from `DT`.

| File | SHA-256 |
|---|---|
| `arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dts` | `d940e608822e31c901c76dd48ccaa7142015e7ad437187420d703ef14cda0d8c` |
| `DT bcm2711-rpi-4-b.dts` | `c69ee77b38dc3c3b7edff87b4cd24f3ed1d54e5b73154d65a84249d53a51feb1` |
| `DT bcm2711.dtsi` | `64fda3a4f8211e17f0cae108ff1fea67804245606ac487d34697e77f1e6f388f` |
| `DT bcm2711-rpi.dtsi` | `13a42cdc5aa8e85a2bca0d058eced7fada8213203ea9eacaf8ad32e3eccfbb47` |
| `DT bcm283x.dtsi` | `999bc1a10e79136b30e1f87633ba4eb2eb9e5d2b79edece0b6d5133625167447` |
| `DT bcm2835-rpi.dtsi` | `92812a622ffc760585c2cce6f5100ffbd89bd95b0524b0474f9023c2c9179d30` |
| `DT bcm283x-rpi-wifi-bt.dtsi` | `d107cf66fbae26525e42e3c9aa595aa1cb8215c9e95f856c19d04bd94a12f166` |
| `MMC host/sdhci-iproc.c` | `f05fdbab5624a2564f4c56e6a1898dbc9f1fb0d06f9f0ad7d2391e118f9689fb` |
| `MMC host/sdhci.c` | `186305e102bd32df419ff80669e6018d6b3a9e4310c3101193413970355b9857` |
| `MMC host/sdhci.h` | `4b3a252cecc039b22e56c37ec95ad2959bee52934594666708c4a7f118afe4af` |
| `MMC host/sdhci-pltfm.c` | `5b0c7b9babcaf8a97f847dded20af3a4b2a9418122282500e0cedeb9329c8c4d` |
| `MMC core/pwrseq_simple.c` | `12c389346a29cf6efc8d8938fb45d5d77c296a283a54fb1b179ed4861a654d6b` |
| `MMC core/core.c` | `56678ec9c220d952b63f4e2af7072f7d3b815cd867c7809c937b5f38cddd5304` |
| `MMC core/core.h` | `7bbefe7ecf2aac58d1b2394fe44bacaf521b90b1ed56603896f97dbfa4ffa341` |
| `MMC core/host.c` | `934fa12c7aa9d25f19a8c344afe4c3d4c1da5ad25bc95a86e7a01585a614b51e` |
| `MMC core/sdio.c` | `cfc4635e4ae8c5690535b3933a4fd5387d3fbe6256f575c8794b074248fbf8f6` |
| `MMC core/sdio_io.c` | `95eeac8c70fd825aff913a316077acbb3514b9a35603ca693c0c5f510bd18198` |
| `MMC core/sdio_ops.c` | `23e6cd52c802263e69e95eacc4054a9afcd751da746ef6fa53f8312f93a7aa29` |
| `MMC core/sdio_cis.c` | `5ff82f36a6c15fb9bb8836ec54bb53c44a0be9210e898a0db647bc702716d118` |
| `MMC core/sdio_irq.c` | `fd5785b240e66db8f658eaaedc22cd647535ea305a9179e7f66b9ae2527deabe` |
| `MMC core/quirks.h` | `52d8b6fd81f48177475d3435d244c86a7c741d764688b267df8299864850ef67` |
| `MMC core/card.h` | `fc6c8db4f5ab5936eec6f7b3a8514cd4a8cde8baf147d9e20eb60d26f88382bd` |
| `FMAC bcmsdh.c` | `a959b3d2085ba4c77cc211703a2932fdd4d09d62d4dc10a95c43ba3fd2a0ea76` |
| `FMAC sdio.c` | `6889d448c8e7fab5cf28c3189675deda19a5d7c6e523895bf280441909fa8b9b` |
| `FMAC of.c` | `a3005c3984c5473277ad67a8da4d718084675b061f0863fc6614d3b33992acf8` |

(Each file's URL is the pattern above with its path in place of PATH.) Also fetched and kept
but not cited: `MMC core/sdio_bus.c`, `MMC core/bus.c`, `MMC core/pwrseq.c`,
`DT bcm283x-rpi-usb-host.dtsi`.

## F2: WL_REG_ON, power sequence, state

1. **The tree names the line "WL_ON" and puts it on the firmware's GPIO expander, not on the
   SoC.** The Pi 4 board file names expander line 1 "WL_ON" (names list, `DT
   bcm2711-rpi-4-b.dts:63-71`, entry 1 at line 65) and points the WiFi power-sequence node's
   reset line at expander line 1 (`DT bcm2711-rpi-4-b.dts:270-272`). The expander is the node
   of compatible `raspberrypi,firmware-gpio`, a child of the firmware node, which is the
   firmware mailbox's GPIO service (`DT bcm2711-rpi.dtsi:46-52`; the firmware node is
   `DT bcm2835-rpi.dtsi:4-7`). It is not one of the SoC's own 58 pins (`DT bcm2711.dtsi:662`).
2. **Polarity: the reset line is declared active-low.** The reference carries the active-low
   flag (`DT bcm2711-rpi-4-b.dts:271`). The power-sequence driver treats "asserted" as the
   chip held in reset, so the pin is physically low while the chip is held in reset or off
   and physically high while the chip is allowed to run. (Reading of the flag against the
   driver's order below; the tree does not label the pin's electrical meaning in words.)
3. **Order of the generic power sequence for this node** (`MMC core/pwrseq_simple.c:63-109`,
   `MMC core/core.c:1338-1370`): (a) assert reset (pin low); (b) mark power-up and wait the
   host's power delay; (c) deassert reset (pin high); (d) wait the power-sequence node's own
   post-power-on delay, if any; (e) turn the bus clock on at the initial frequency; (f) wait
   the host's power delay again. Power off asserts reset (pin low), waits the node's
   power-off delay, if any, then drops any external clock (`pwrseq_simple.c:92-109`).
4. **Delays the tree states: none of its own.** The power-sequence node carries only its
   compatible string and the reset reference (`DT bcm283x-rpi-wifi-bt.dtsi:4-6`, `DT
   bcm2711-rpi-4-b.dts:270-272`); neither `post-power-on-delay-ms` nor `power-off-delay-us`
   appears anywhere in the board's files, so the node's two delays are zero (the driver
   reads both as optional, `pwrseq_simple.c:159-162` region, defaults zero because the
   struct is zero-filled at `pwrseq_simple.c:129`).
5. **The delays that do apply come from the host core: 10 ms, twice.** The host's power
   delay defaults to 10 ms (`MMC core/host.c:576`), and the same property name the
   power-sequence node would use is read for the host from its own node (`host.c:421-422`),
   which the SDHCI node does not set. Delays of 20 ms or less are slept as a range of 1.0 to
   1.25 times the request (`MMC core/core.h:68-74`). So the sequence is: reset low, about
   10 ms, reset high, no further wait, clock on, about 10 ms, then the first command.
6. **A single reset line takes a different code path with the same order.** When the node
   lists exactly one reset line, the driver uses a shared reset-control object instead of a
   GPIO array (`pwrseq_simple.c:137-141`), and its assert/deassert calls run in the same
   order as items (a), (c) above (`pwrseq_simple.c:72-76`, `83-86`, `96-99`). Which of the
   two paths Linux takes for the Pi does not change the electrical order.
7. **The GPIO-array path requests the line already asserted.** If the GPIO path is taken,
   the line is requested with an initial output of "asserted" (`pwrseq_simple.c:149`
   region), so Linux does not assume the chip is on or off when it starts: it drives the pin
   to reset first. The tree says nothing about the pin's state when the firmware hands over;
   no `gpio-hog`, `default-state` or `regulator-boot-on` appears for it. State at handover
   is unknown to the tree.
8. **The WiFi node is marked non-removable and has no card-detect line**
   (`DT bcm283x-rpi-wifi-bt.dtsi:16`); the power sequence is therefore run once at attach,
   not on insertion events.

## F3: host-wake out-of-band interrupt

9. **The tree gives no out-of-band interrupt line to the WiFi chip.** The WiFi child node
   (`wifi@1`, compatible `brcm,bcm4329-fmac`, `reg = <1>`) has only those two properties
   (`DT bcm283x-rpi-wifi-bt.dtsi:20-23`): no `interrupts`, `interrupt-parent`,
   `interrupt-names`, and no `brcm,drive-strength`. The Pi 4 board file does not extend the
   node (`brcmf` is not referenced in `DT bcm2711-rpi-4-b.dts`).
10. **What the driver does with no such property.** It reads interrupt index 0 of the node
    and, if there is none, returns without setting out-of-band mode (`FMAC of.c:141-143`);
    only with one does it record the interrupt number and trigger flags (`of.c:145-154`).
    Without one, brcmfmac claims the SDIO core's in-band interrupt on functions 1 and 2
    (`FMAC bcmsdh.c:157-162` region, the `else` branch of the registration function that
    starts at `bcmsdh.c:97`) and sets its own poll flag false and interrupt flag true
    (`FMAC sdio.c:4085-4089`). So on the Pi 4 Linux uses in-band card interrupts.
11. **Other interrupt-related tree facts.** The legacy controller's own interrupt is shared
    peripheral interrupt 126, level high (`DT bcm2711.dtsi:1147-1149`); the base file's
    `interrupts = <2 30>` is overridden for the 2711. The Bluetooth node has a shutdown line
    on expander line 0 ("BT_ON") but no host-wake either (`DT bcm2711-rpi-4-b.dts:51-53`);
    it is not part of WiFi.

## F5: bus width and maximum clock

12. **Bus width 4.** The SDHCI node that carries the WiFi chip sets `bus-width = <4>`
    (`DT bcm283x-rpi-wifi-bt.dtsi:15`); the host core turns 4 into the 4-bit capability
    (`MMC core/host.c:274-287`). The core then asks the card, through the SDIO common
    registers, to switch to 4-bit only if the host has the capability and the card's own
    capability bits do not say it is low-speed-without-wide (`MMC core/sdio.c:261-285`,
    `sdio.c:374-388`).
13. **No maximum-frequency property.** Neither the board file nor the included dtsi files give
    `max-frequency` or `max-sd-hs-hz` for this node (`DT bcm283x-rpi-wifi-bt.dtsi:10-24`;
    the core reads `max-frequency` as an optional limit at `MMC core/host.c:296-297`). The
    host's limit is therefore its own base clock: the maximum is clamped to the base clock
    (`MMC host/sdhci.c:4498-4499`).
14. **Frequency Linux asks the card for.** After enumeration the core sets the clock to 50 MHz for a card in
    high-speed mode, otherwise to the rate in the card's CIS
    (`MMC core/sdio.c:440-463`, `sdio.c:885`); it switches the card to high-speed in CCCR
    only when the host advertises the high-speed capability and the card's CCCR says it can
    (`sdio.c:396-420`). If the card shows no high-speed support the core records a 25 MHz
    limit and otherwise 50 MHz (`sdio.c:247-253`). The controller advertises high-speed
    capability (fact 20), so for a card that supports it Linux runs the slot at up to 50 MHz,
    capped by the base clock and the divider choices.
15. **The initial identification rate is 400 kHz.** The host's initial frequency is 400 kHz, clamped to the
    controller's range (the list 400/300/200/100 kHz is the fallback retry list)
    (`MMC core/core.c:53`, `core.c:2344`). The legacy controller has no override of the
    minimum clock; only the BCM2711's other controller (`brcm,bcm2711-emmc2`) raises its
    minimum to 200 kHz (`MMC host/sdhci-iproc.c:179-181`, `288-296`, `322-323`), and that is
    not the WiFi controller.

## F6: quirks of Linux's driver for this controller

The WiFi slot's controller is the "SDHCI" node of compatible `brcm,bcm2835-sdhci` at bus
address 0x7e300000 (`DT bcm283x.dtsi:423-428`); the other SD host on the 2711, "sdhost",
stays disabled (`DT bcm283x.dtsi:314-320`, no override in the board files). Linux binds the
iProc driver to the compatible and gives it the 2835 data set (`MMC host/sdhci-iproc.c:322`).
The 2711's SD card controller `emmc2` is a different node and driver data (`DT
bcm2711.dtsi:426-431`; `sdhci-iproc.c:323`).

16. **32-bit-only register access.** The driver's access hooks for this controller read and
    write only whole 32-bit registers; byte and half-word accesses are done as read, merge,
    write of the containing word (`sdhci-iproc.c:192-203`, `35-70` region, `147-155`).
17. **Back-to-back write loss, worked around with shadows.** The comment in the driver says
    the controller can lose the contents of consecutive writes to the same register that
    land within two SD clocks. The driver holds the block-size/block-count word and the
    transfer-mode word in memory and writes each as one 32-bit write only when the command
    register is written: first block size/count, then transfer-mode plus command
    (`sdhci-iproc.c:86-146`, especially `106-145`). Reads of those registers return the held
    values meanwhile (`sdhci-iproc.c:46-69` region).
18. **Delay after every register write at low clock.** After each 32-bit write, while the
    bus clock is 400 kHz or lower, the driver waits four SD clocks rounded up to a whole
    microsecond; with the clock at zero it waits 10 microseconds (`sdhci-iproc.c:71-84`).
19. **Quirk flags set for this controller** (`sdhci-iproc.c:252-258`; meanings from
    `MMC host/sdhci.h`):
    - broken card detection (`sdhci.h:463`): the driver assumes the card is always present
      (`MMC host/sdhci.c:2533-2534`) and, if the node were removable, would poll
      (`sdhci.c:4575-4578`); the node is non-removable so this adds nothing;
    - data timeout counted in SD clocks, not a separate timeout clock (`sdhci.h:481`;
      `sdhci.c:2400-2410`, `4501`): the timeout the controller is given is computed from
      the bus clock, in the kilohertz of the actual clock;
    - no high-speed bit (`sdhci.h:489`; `sdhci.c:2436`): the controller's host-control
      high-speed bit is never set for any timing, even though the card is switched into
      high-speed mode;
    - second-set flag: presets are broken (`sdhci.h:499`; `sdhci.c:2338`, `2368`, `3905`):
      Linux does not use the preset-value registers for clock or signaling setup.
    No auto-CMD12 quirk, no multiblock-off quirk, and no DMA-off quirk is set for it.
20. **The capabilities register is not trusted; Linux substitutes values.** The 2835 data set
    marks its capabilities as missing and the driver reads them from fixed values instead
    (`sdhci-iproc.c:260-270`, `394-398`). The substituted values: maximum block size code 1
    (so 1024 bytes, see fact 25), 3.3 V supported, high-speed supported; in capabilities 1,
    driver types A and C and nothing else (so no 1.8 V or UHS modes). The base clock field is
    not among them, so it reads as zero and the core asks the driver for the base clock
    (`MMC host/sdhci.c:4449-4462`); see fact 21.
21. **Base clock: from the clock framework, not from a register.** The driver's
    maximum-clock hook returns the enabled clock's current rate (`sdhci-iproc.c:157-165`;
    `MMC host/sdhci-pltfm.c:27-32`). The node's `clocks` reference is the 2835 clock-manager
    clock named EMMC (`DT bcm283x.dtsi:423-428`: `BCM2835_CLOCK_EMMC`). On the Pi the 2711's
    clock-manager node carries the 2711's compatible and the oscillator is 54 MHz (`DT
    bcm2711.dtsi:633-640`). The tree states no rate for this clock for the WiFi slot (no
    `assigned-clock-rates` on the SDHCI node); the firmware sets it (unverified by the tree).
22. **1.8 V and regulators: none for the legacy slot.** The 3.3 V/1.8 V select regulator and
    the card-power regulator are wired to `emmc2` (the SD card), not to the WiFi SDHCI node
    (`DT bcm2711-rpi-4-b.dts:26-48`, `191-196`). The WiFi node has no `vmmc` or `vqmmc`.
23. **SDIO interrupt support is advertised unconditionally by the core driver**
    (`MMC host/sdhci.c:4532`): the card-interrupt bit is the controller's way to deliver
    the card's in-band interrupt (`sdhci.c:2596-2607`). The iProc code has no override
    for it.

## F7: byte-mode CMD53 limits and delays after function enable

24. **Byte-mode request layout.** For a byte-mode CMD53 the count field carries the byte
    count, with 512 encoded as 0; block mode sets the block-mode bit and carries the block
    count (`MMC core/sdio_ops.c:135-148`, especially `140-143`). The register address must
    fit 17 bits (`sdio_ops.c:128-130`).
25. **Maximum byte-mode length.** The core's limit is the smallest of: the host's maximum
    block size (1024 for this controller, fact 20; `MMC host/sdhci.c:4815-4833`), the
    function's maximum block size read from its CIS (`MMC core/sdio_io.c:187-199`; a
    function-extension tuple field read at `MMC core/sdio_cis.c:195-196`), and 512
    (`sdio_io.c:199`). Two card quirks can change it, "block size for byte mode" (uses the
    current block size instead of the CIS maximum) and "broken byte mode 512" (limit 511);
    Linux's table does not list any Broadcom or Cypress device for either
    (`MMC core/quirks.h:195-224`, `card.h:244-266`). The table's matches for these quirks are
    other vendors' chips.
26. **When block mode is used.** Block mode is chosen when the card says it supports
    multi-block and the transfer is longer than the byte-mode limit; the bulk is sent in
    whole blocks of the function's current block size, at most min(host maximum blocks,
    511) blocks per command (the host maximum is 65535 for this controller,
    `sdhci.c:4838`); the tail shorter than a block goes as byte mode, in pieces of the
    byte-mode limit (`sdio_io.c:300-356`). Size alignment helper: a size is first aligned
    by the controller, then left alone if byte mode suffices, else rounded to a whole number
    of blocks if multi-block is supported (`sdio_io.c:235-260`).
27. **brcmfmac's block sizes.** It sets function 1 to a block size of 64 bytes (`FMAC
    bcmsdh.c:44`, `907`). For function 2 the default is 512, with 256 for some chips and 128
    for the 4329 (`bcmsdh.c:45-48`, `911-936`); the chips in the 256 list are device ids
    43752, Cypress 4373, 4359, 4354 and 4356. The 4345 and 43455 ids are not in any list,
    so the 43455 gets function 2 at 512 bytes (`bcmsdh.c:910-930`, `994-995`). The core
    caps a requested block size at the host's maximum, and 0 means min of the function's
    CIS maximum, the host maximum and 512 (`sdio_io.c:159-180`).
28. **Delay after function enable in the core.** Enabling a function sets its bit in the
    I/O-enable register, then polls the I/O-ready register back-to-back with no sleep between
    reads until the function's bit is set or its enable timeout passes, whichever is first;
    the poll has no delay in its loop body (`MMC core/sdio_io.c:59-101`, loop at `80-92`).
    The timeout is the function's CIS-supplied value in units of 10 ms, or 1 second when the
    SDIO revision is 1.0 (`MMC core/sdio_cis.c:201-204`).
29. **brcmfmac's timeouts.** It raises function 2's enable timeout to 3000 ms (`FMAC
    bcmsdh.c:50`, `939-940`). Function 1 is enabled in its probe path before any firmware
    is loaded (`bcmsdh.c:943`); function 2 is enabled later, after firmware and NVRAM are
    downloaded (`FMAC sdio.c:4270`), with the backplane clock first forced on
    (`sdio.c:4254-4268` region) and the mailbox data word written with the protocol version
    just before the enable (`sdio.c:4268-4269`). After a successful function-2 enable it
    programs the host interrupt mask, then, by device id, a watermark and a busy-control
    value; for 43455 the values are 0x60 and 0x50 with the busy-control set to the 0x50
    value ORed with a flag (`sdio.c:54-56`, `4281-4345` region, the 43455 case). The 4345
    id has no case of its own there.
30. **Other brcmfmac delays and polls on this chip family.**
    - Waking the chip through its keep-SDIO-on bit: sleep 2 to 3 ms, then read back until
      both the keep-on bit and the device-on status read set; between retries wait 50 us and
      rewrite; the retry count is derived from 1,000,000 us divided by 50 us
      (`FMAC sdio.c:326-327`, `311-312`, `700-770`).
    - Waiting for the high-throughput clock: poll the clock control/status register every
      5 to 10 ms for up to 1,000 ms (`sdio.c:845-858`, `311-312`).
    - 65 us after forcing the ALP clock and before disabling the extra pull-ups
      (`sdio.c:3854-3884`).
    - 20 ms before putting the chip passive on removal (`sdio.c:4595-4606`).
    - Driver response timeouts: 2500 ms for both firmware command responses and control
      transfers (`sdio.c:39-40`).
    - It writes a card capability register in the common area to add CMD14 support, and
      sets a wakeup-control bit and a clock request, at bring-up (`sdio.c:3440-3485`).
    - It writes the drive-strength default of 6 mA unless the node gives one
      (`sdio.c:539`, `4040-4050` region; node property read at `FMAC of.c:138-139`).
    - It sets a card-control bit so an SDIO card reset also resets the WLAN backplane
      (`sdio.c:4051-4057`).
31. **How the SDIO core brings the card up** (relevant to ordering, not tied to this chip):
    an SDIO function-0 abort write with the reset bit, then go-idle, then interface
    condition, then an I/O operating-condition request with a zero argument
    (`MMC core/sdio.c:640-651`, `MMC core/sdio_ops.c:202-216`). The comment in the core says
    the reset step is optional for non-removable cards but harmless. The operating-condition
    exchange and later steps follow in `sdio.c`; the core gives the card no extra delay
    between them beyond the command timeouts.
32. **The SDIO interrupt thread polls in the absence of a controller interrupt, at 10 ms
    idle, backing off to 1 s** (`MMC core/sdio_irq.c:151-193`). The legacy controller
    delivers card interrupts, and the host sets a flag that makes the core handle them in a
    non-threaded context (`MMC host/sdhci.c:4532-4533`), so that polling thread is the
    fallback only.

## F1 and F4: what the tree states (board-probe facts; not settled here)

33. **F1: pin group.** The legacy controller's pin group `emmc_gpio34` covers GPIO 34 to 39
    and selects alternate function 3 (`DT bcm283x.dtsi:148-157`). The WiFi SDHCI node uses
    exactly this group in its default pin state (`DT bcm283x-rpi-wifi-bt.dtsi:13-14`). The
    group sets pull-ups: GPIO 34 (the clock) no pull, GPIO 35 to 39 pull-up (`bcm283x.dtsi:
    151-156`). GPIO 34 is the clock, 35 the command line, 36 to 39 the four data lines, going
    by the group order and the legacy controller's usual numbering; the tree does not label
    them. Whether the firmware has already set this state at handover is not stated by the
    tree.
34. **F4: base clock.** The tree names the clock only by reference (`BCM2835_CLOCK_EMMC` of
    the clock manager, `DT bcm283x.dtsi:427`), and gives no frequency for it (see fact 21).
    The oscillator for the 2711's clock manager is 54 MHz (`DT bcm2711.dtsi:633-635`). The
    firmware-owned clocks (`firmware_clocks`) used elsewhere in the tree are not referenced
    by the WiFi SDHCI node.

## Open questions

- State of WL_REG_ON when the firmware hands over, and whether its expander line can be
  reached other than through the firmware: the tree does not say (facts 1, 7). This is a
  board-probe fact.
- Whether the Pi 4's WiFi chip needs any delay beyond the 10 ms and 10 ms of fact 5; the
  tree and Linux add none, but that is not evidence about the chip's datasheet minimum.
- Which clock rate the firmware leaves EMMC at, and so the base clock for the slot (facts 21,
  34): board probe.
- Which SDIO function-extension maximum block size the CYW43455's CIS reports for function 2
  (needed for the byte-mode limit of fact 25): not in these sources.
- Which of the two code paths of fact 6 Linux takes on the Pi (reset control or GPIO array)
  depends on whether an aux reset-gpio driver is enabled in the build; this is not shown in
  the files read. The electrical order is the same.
- Whether the firmware honours `gpio=` lines for GPIO 34 to 39 (F1's mitigation): not a
  Linux fact.
- Fact 30's retry counts and Linux's poll intervals are Linux's choices; none is stated by
  Broadcom or Cypress in these files.
- `SDIO_DEVICE_ID_BROADCOM_43455` and `4345` values live in a header not fetched
  (`include/linux/mmc/sdio_ids.h`); the record cites the names only.
