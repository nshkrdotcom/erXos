/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The Raspberry Pi 4 header probe: the kernel8.img of the header probe
 * card (tools/lib/erx/header_probe.rb), for the first two items of the
 * board checklist in docs/design-header-io.md, "Verification", whose
 * results docs/research-rpi4-header-probe.md records. No erXos image
 * links it; only the probe card carries it.
 *
 * BL31 enters it in bootstrap's place, in EL2 with the MMU off and only
 * this CPU running, so it sees the pins and the clock as the firmware
 * left them. It reads registers only, through the generated accessors of
 * hw/svd/bcm2711_gpio, hw/svd/cprman and hw/svd/mini_uart, and writes no
 * register but the console's data register. In order, it writes on the
 * console:
 *
 * 1. "erXos header probe REV": the build;
 * 2. "regs boot": the GPIO and clock-manager registers of the checklist,
 *    read at entry, each with its fields decoded;
 * 3. "CNTFRQ_EL0": the generic timer's frequency, which times the rest;
 * 4. "keys": GPLEV0's bit for the console's receive pin, sampled for
 *    KEY_SECONDS while the person at the console types, beside the
 *    bytes the console received meanwhile;
 * 5. "regs minute": the same registers SNAPSHOT_SECONDS after entry,
 *    after a line saying how many seconds after entry they were read;
 * 6. "done".
 *
 * A register the probe cannot read ends it early with a "stopped" line.
 * Every line starts with LINE_TAG, so a reader takes the probe's lines
 * from a log that holds the firmware's and BL31's too.
 *
 * The builder passes, as macros: CONSOLE_BASE and CONSOLE_SIZE, the
 * console's window from the platform record; GPIO_WINDOW and CM_WINDOW,
 * the sizes of the GPIO and clock-manager SVDs' windows; CONSOLE_RX_PIN,
 * the pin the pin table gives the console's receive signal; and
 * PROBE_REVISION, a string naming the erXos commit the card was built
 * from.
 *
 * No exception vectors are installed: a fault hangs the probe after its
 * last line, which says roughly where.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/arch/aarch64/sysreg.h"
#include "erx/hw/bcm2711_gpio.h"
#include "erx/hw/cprman.h"
#include "erx/hw/mini_uart.h"

#define	LINE_TAG		"hp: "
#define	SNAPSHOT_SECONDS	60
#define	KEY_SECONDS		20
#define	NITEMS(array)		(sizeof(array) / sizeof((array)[0]))

/*
 * The blocks' bases, from the BCM2711 ARM Peripherals datasheet, release
 * 4 (DS), which gives legacy master addresses: in Low Peripheral mode,
 * which the firmware sets on this board (the platform record's console
 * lies at 0xfe215040), the CPU sees legacy 0x7enn_nnnn at 0xfenn_nnnn
 * (DS 1.2.4).
 */
#define	DS_CPU(legacy)	((legacy) - UINT32_C(0x7e000000) + UINT32_C(0xfe000000))
#define	GPIO_BASE	DS_CPU(UINT32_C(0x7e200000))	/* DS 5.2 */
#define	CM_BASE		DS_CPU(UINT32_C(0x7e101000))	/* DS 5.4.2 */

/* GPLEV0 holds GPIO 0 to 31; the pin table's pins are bank 0's. */
_Static_assert(CONSOLE_RX_PIN < 32, "the console's receive pin is not in GPLEV0");

typedef uint32_t field_get_t(uint32_t);
typedef bool register_read_t(erx_mmio_t, uint32_t *);

typedef struct pin_field pin_field_t;

/* One pin's field of a register that holds a field for each pin. */
struct pin_field {
	uint32_t	 pin;
	field_get_t	*get;
};

typedef struct registers registers_t;

/* The checklist's registers, read together so they show one moment. */
struct registers {
	uint32_t	gpfsel0;
	uint32_t	gpfsel1;
	uint32_t	gpfsel2;
	uint32_t	pup_pdn0;
	uint32_t	pup_pdn1;
	uint32_t	gpren0;
	uint32_t	gpfen0;
	uint32_t	gparen0;
	uint32_t	gpafen0;
	uint32_t	gphen0;
	uint32_t	gplen0;
	uint32_t	pwmctl;
	uint32_t	pwmdiv;
};

typedef struct key_sample key_sample_t;

/* What the keys phase saw. */
struct key_sample {
	uint64_t	samples;
	uint64_t	low_samples;
	uint64_t	transitions;
	uint64_t	bytes;
	uint32_t	first_level;
};

void		header_probe(void);

static const erx_mmio_t console = {
	.base = (volatile uint8_t *)(uintptr_t)CONSOLE_BASE,
	.length = CONSOLE_SIZE
};
static const erx_mmio_t gpio = {
	.base = (volatile uint8_t *)(uintptr_t)GPIO_BASE,
	.length = GPIO_WINDOW
};
static const erx_mmio_t cm = {
	.base = (volatile uint8_t *)(uintptr_t)CM_BASE,
	.length = CM_WINDOW
};

/* The function select and pull fields of GPIO 0 to 29 and 0 to 31. */
static const pin_field_t gpfsel0_fields[] = {
	{ 0, erx_bcm2711_gpio_gpfsel0_fsel0_get },
	{ 1, erx_bcm2711_gpio_gpfsel0_fsel1_get },
	{ 2, erx_bcm2711_gpio_gpfsel0_fsel2_get },
	{ 3, erx_bcm2711_gpio_gpfsel0_fsel3_get },
	{ 4, erx_bcm2711_gpio_gpfsel0_fsel4_get },
	{ 5, erx_bcm2711_gpio_gpfsel0_fsel5_get },
	{ 6, erx_bcm2711_gpio_gpfsel0_fsel6_get },
	{ 7, erx_bcm2711_gpio_gpfsel0_fsel7_get },
	{ 8, erx_bcm2711_gpio_gpfsel0_fsel8_get },
	{ 9, erx_bcm2711_gpio_gpfsel0_fsel9_get },
};

static const pin_field_t gpfsel1_fields[] = {
	{ 10, erx_bcm2711_gpio_gpfsel1_fsel10_get },
	{ 11, erx_bcm2711_gpio_gpfsel1_fsel11_get },
	{ 12, erx_bcm2711_gpio_gpfsel1_fsel12_get },
	{ 13, erx_bcm2711_gpio_gpfsel1_fsel13_get },
	{ 14, erx_bcm2711_gpio_gpfsel1_fsel14_get },
	{ 15, erx_bcm2711_gpio_gpfsel1_fsel15_get },
	{ 16, erx_bcm2711_gpio_gpfsel1_fsel16_get },
	{ 17, erx_bcm2711_gpio_gpfsel1_fsel17_get },
	{ 18, erx_bcm2711_gpio_gpfsel1_fsel18_get },
	{ 19, erx_bcm2711_gpio_gpfsel1_fsel19_get },
};

static const pin_field_t gpfsel2_fields[] = {
	{ 20, erx_bcm2711_gpio_gpfsel2_fsel20_get },
	{ 21, erx_bcm2711_gpio_gpfsel2_fsel21_get },
	{ 22, erx_bcm2711_gpio_gpfsel2_fsel22_get },
	{ 23, erx_bcm2711_gpio_gpfsel2_fsel23_get },
	{ 24, erx_bcm2711_gpio_gpfsel2_fsel24_get },
	{ 25, erx_bcm2711_gpio_gpfsel2_fsel25_get },
	{ 26, erx_bcm2711_gpio_gpfsel2_fsel26_get },
	{ 27, erx_bcm2711_gpio_gpfsel2_fsel27_get },
	{ 28, erx_bcm2711_gpio_gpfsel2_fsel28_get },
	{ 29, erx_bcm2711_gpio_gpfsel2_fsel29_get },
};

static const pin_field_t pup_pdn0_fields[] = {
	{ 0, erx_bcm2711_gpio_pup_pdn0_pull0_get },
	{ 1, erx_bcm2711_gpio_pup_pdn0_pull1_get },
	{ 2, erx_bcm2711_gpio_pup_pdn0_pull2_get },
	{ 3, erx_bcm2711_gpio_pup_pdn0_pull3_get },
	{ 4, erx_bcm2711_gpio_pup_pdn0_pull4_get },
	{ 5, erx_bcm2711_gpio_pup_pdn0_pull5_get },
	{ 6, erx_bcm2711_gpio_pup_pdn0_pull6_get },
	{ 7, erx_bcm2711_gpio_pup_pdn0_pull7_get },
	{ 8, erx_bcm2711_gpio_pup_pdn0_pull8_get },
	{ 9, erx_bcm2711_gpio_pup_pdn0_pull9_get },
	{ 10, erx_bcm2711_gpio_pup_pdn0_pull10_get },
	{ 11, erx_bcm2711_gpio_pup_pdn0_pull11_get },
	{ 12, erx_bcm2711_gpio_pup_pdn0_pull12_get },
	{ 13, erx_bcm2711_gpio_pup_pdn0_pull13_get },
	{ 14, erx_bcm2711_gpio_pup_pdn0_pull14_get },
	{ 15, erx_bcm2711_gpio_pup_pdn0_pull15_get },
};

static const pin_field_t pup_pdn1_fields[] = {
	{ 16, erx_bcm2711_gpio_pup_pdn1_pull16_get },
	{ 17, erx_bcm2711_gpio_pup_pdn1_pull17_get },
	{ 18, erx_bcm2711_gpio_pup_pdn1_pull18_get },
	{ 19, erx_bcm2711_gpio_pup_pdn1_pull19_get },
	{ 20, erx_bcm2711_gpio_pup_pdn1_pull20_get },
	{ 21, erx_bcm2711_gpio_pup_pdn1_pull21_get },
	{ 22, erx_bcm2711_gpio_pup_pdn1_pull22_get },
	{ 23, erx_bcm2711_gpio_pup_pdn1_pull23_get },
	{ 24, erx_bcm2711_gpio_pup_pdn1_pull24_get },
	{ 25, erx_bcm2711_gpio_pup_pdn1_pull25_get },
	{ 26, erx_bcm2711_gpio_pup_pdn1_pull26_get },
	{ 27, erx_bcm2711_gpio_pup_pdn1_pull27_get },
	{ 28, erx_bcm2711_gpio_pup_pdn1_pull28_get },
	{ 29, erx_bcm2711_gpio_pup_pdn1_pull29_get },
	{ 30, erx_bcm2711_gpio_pup_pdn1_pull30_get },
	{ 31, erx_bcm2711_gpio_pup_pdn1_pull31_get },
};

/*
 * The entry, first in the image (header_probe.ld puts .text.entry
 * there): the stack the linker script reserves, then header_probe.
 * header_probe returns only when done.
 */
__asm__(
    ".section .text.entry, \"ax\"\n"
    ".globl header_probe_entry\n"
    "header_probe_entry:\n"
    "	adrp	x1, header_probe_stack_top\n"
    "	add	x1, x1, :lo12:header_probe_stack_top\n"
    "	mov	sp, x1\n"
    "	bl	header_probe\n"
    "1:	wfe\n"
    "	b	1b\n"
    ".text\n");

/* The console: one byte out, with a bounded wait for room. */
static void
put_byte(uint8_t byte)
{
	uint32_t status;

	for (uint32_t spins = 0; spins < 1000000; spins++) {
		if (!erx_mini_uart_lsr_read(console, &status))
			return;
		if (erx_mini_uart_lsr_tx_empty_get(status) != 0)
			break;
	}
	(void)erx_mini_uart_io_write(console, byte);
}

/* A byte the console received, if one is waiting. */
static bool
take_byte(void)
{
	uint32_t status, data;

	if (!erx_mini_uart_lsr_read(console, &status) ||
	    erx_mini_uart_lsr_data_ready_get(status) == 0)
		return (false);
	return (erx_mini_uart_io_read(console, &data));
}

static void
put_str(const char *text)
{
	for (; *text != '\0'; text++)
		put_byte((uint8_t)*text);
}

static void
line_start(const char *what)
{
	put_str(LINE_TAG);
	put_str(what);
}

static void
line_end(void)
{
	put_str("\r\n");
}

static void
put_hex32(uint32_t value)
{
	static const char hex[] = "0123456789abcdef";

	put_str("0x");
	for (int shift = 28; shift >= 0; shift -= 4)
		put_byte((uint8_t)hex[(value >> shift) & 0xf]);
}

static void
put_dec(uint64_t value)
{
	char digits[20];
	int count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0)
		put_byte((uint8_t)digits[--count]);
}

/*
 * A function select field's value as DS Table 64 names it. Every FSEL
 * field has that encoding, which the SVD repeats for each pin, so FSEL0's
 * names stand for all.
 */
static const char *
fsel_name(uint32_t value)
{
	switch (value) {
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_INPUT:
		return ("in");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_OUTPUT:
		return ("out");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT0:
		return ("a0");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT1:
		return ("a1");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT2:
		return ("a2");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT3:
		return ("a3");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4:
		return ("a4");
	case ERX_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5:
		return ("a5");
	default:
		return ("?");
	}
}

/* A pull field's value as DS Table 90 names it; PULL0's names stand for all. */
static const char *
pull_name(uint32_t value)
{
	switch (value) {
	case ERX_BCM2711_GPIO_PUP_PDN0_PULL0_NONE:
		return ("none");
	case ERX_BCM2711_GPIO_PUP_PDN0_PULL0_UP:
		return ("up");
	case ERX_BCM2711_GPIO_PUP_PDN0_PULL0_DOWN:
		return ("down");
	default:
		return ("reserved");
	}
}

/* The PWM clock's source as DS Table 99 names it; 8 to 15 are GND too. */
static const char *
source_name(uint32_t value)
{
	switch (value) {
	case ERX_CPRMAN_PWMCTL_SRC_OSCILLATOR:
		return ("oscillator");
	case ERX_CPRMAN_PWMCTL_SRC_TESTDEBUG0:
		return ("testdebug0");
	case ERX_CPRMAN_PWMCTL_SRC_TESTDEBUG1:
		return ("testdebug1");
	case ERX_CPRMAN_PWMCTL_SRC_PLLA_PER:
		return ("PLLA per");
	case ERX_CPRMAN_PWMCTL_SRC_PLLC_PER:
		return ("PLLC per");
	case ERX_CPRMAN_PWMCTL_SRC_PLLD_PER:
		return ("PLLD per");
	case ERX_CPRMAN_PWMCTL_SRC_HDMI_AUXILIARY:
		return ("HDMI auxiliary");
	default:
		return ("GND");
	}
}

static void
register_start(const char *when, const char *name, uint32_t value)
{
	line_start("regs ");
	put_str(when);
	put_byte(' ');
	put_str(name);
	put_str(" = ");
	put_hex32(value);
}

/* A register with a field for each pin: PIN=NAME for each. */
static void
pins_show(const char *when, const char *name, uint32_t value,
    const pin_field_t *fields, size_t count, const char *(*field_name)(uint32_t))
{
	register_start(when, name, value);
	for (size_t i = 0; i < count; i++) {
		put_byte(' ');
		put_dec(fields[i].pin);
		put_byte('=');
		put_str(field_name(fields[i].get(value)));
	}
	line_end();
}

/*
 * An edge or level detect enable, whose one field holds a bit for each of
 * GPIO 0 to 31, GPIO n at bit n: the pins whose bit is set.
 */
static void
enables_show(const char *when, const char *name, uint32_t value, uint32_t pins)
{
	register_start(when, name, value);
	put_str(" set:");
	for (uint32_t pin = 0; pin < 32; pin++) {
		if ((pins >> pin & 1) != 0) {
			put_byte(' ');
			put_dec(pin);
		}
	}
	line_end();
}

static void
field_show(const char *name, uint32_t value)
{
	put_byte(' ');
	put_str(name);
	put_byte(' ');
	put_dec(value);
}

static void
clock_show(const char *when, uint32_t ctl, uint32_t div)
{
	register_start(when, "CM_PWMCTL", ctl);
	field_show("src", erx_cprman_pwmctl_src_get(ctl));
	put_str(" (");
	put_str(source_name(erx_cprman_pwmctl_src_get(ctl)));
	put_byte(')');
	field_show("enab", erx_cprman_pwmctl_enab_get(ctl));
	field_show("kill", erx_cprman_pwmctl_kill_get(ctl));
	field_show("busy", erx_cprman_pwmctl_busy_get(ctl));
	field_show("flip", erx_cprman_pwmctl_flip_get(ctl));
	field_show("mash", erx_cprman_pwmctl_mash_get(ctl));
	line_end();
	register_start(when, "CM_PWMDIV", div);
	field_show("divi", erx_cprman_pwmdiv_divi_get(div));
	field_show("divf", erx_cprman_pwmdiv_divf_get(div));
	line_end();
}

typedef struct register_source register_source_t;

/* Where a register of the snapshot comes from and where it goes. */
struct register_source {
	register_read_t		*read;
	const erx_mmio_t	*window;
	uint32_t		*into;
};

/* Reads every register of the snapshot; false at the first it cannot. */
static bool
registers_read(registers_t *regs)
{
	const register_source_t sources[] = {
		{ erx_bcm2711_gpio_gpfsel0_read, &gpio, &regs->gpfsel0 },
		{ erx_bcm2711_gpio_gpfsel1_read, &gpio, &regs->gpfsel1 },
		{ erx_bcm2711_gpio_gpfsel2_read, &gpio, &regs->gpfsel2 },
		{ erx_bcm2711_gpio_pup_pdn0_read, &gpio, &regs->pup_pdn0 },
		{ erx_bcm2711_gpio_pup_pdn1_read, &gpio, &regs->pup_pdn1 },
		{ erx_bcm2711_gpio_gpren0_read, &gpio, &regs->gpren0 },
		{ erx_bcm2711_gpio_gpfen0_read, &gpio, &regs->gpfen0 },
		{ erx_bcm2711_gpio_gparen0_read, &gpio, &regs->gparen0 },
		{ erx_bcm2711_gpio_gpafen0_read, &gpio, &regs->gpafen0 },
		{ erx_bcm2711_gpio_gphen0_read, &gpio, &regs->gphen0 },
		{ erx_bcm2711_gpio_gplen0_read, &gpio, &regs->gplen0 },
		{ erx_cprman_pwmctl_read, &cm, &regs->pwmctl },
		{ erx_cprman_pwmdiv_read, &cm, &regs->pwmdiv }
	};

	for (size_t i = 0; i < NITEMS(sources); i++) {
		if (!sources[i].read(*sources[i].window, sources[i].into))
			return (false);
	}
	return (true);
}

/* Every register first, then the lines; false if one cannot be read. */
static bool
registers_snapshot(const char *when)
{
	registers_t regs;

	if (!registers_read(&regs))
		return (false);
	pins_show(when, "GPFSEL0", regs.gpfsel0, gpfsel0_fields,
	    NITEMS(gpfsel0_fields), fsel_name);
	pins_show(when, "GPFSEL1", regs.gpfsel1, gpfsel1_fields,
	    NITEMS(gpfsel1_fields), fsel_name);
	pins_show(when, "GPFSEL2", regs.gpfsel2, gpfsel2_fields,
	    NITEMS(gpfsel2_fields), fsel_name);
	pins_show(when, "PUP_PDN0", regs.pup_pdn0, pup_pdn0_fields,
	    NITEMS(pup_pdn0_fields), pull_name);
	pins_show(when, "PUP_PDN1", regs.pup_pdn1, pup_pdn1_fields,
	    NITEMS(pup_pdn1_fields), pull_name);
	enables_show(when, "GPREN0", regs.gpren0,
	    erx_bcm2711_gpio_gpren0_ren_get(regs.gpren0));
	enables_show(when, "GPFEN0", regs.gpfen0,
	    erx_bcm2711_gpio_gpfen0_fen_get(regs.gpfen0));
	enables_show(when, "GPAREN0", regs.gparen0,
	    erx_bcm2711_gpio_gparen0_aren_get(regs.gparen0));
	enables_show(when, "GPAFEN0", regs.gpafen0,
	    erx_bcm2711_gpio_gpafen0_afen_get(regs.gpafen0));
	enables_show(when, "GPHEN0", regs.gphen0,
	    erx_bcm2711_gpio_gphen0_hen_get(regs.gphen0));
	enables_show(when, "GPLEN0", regs.gplen0,
	    erx_bcm2711_gpio_gplen0_len_get(regs.gplen0));
	clock_show(when, regs.pwmctl, regs.pwmdiv);
	return (true);
}

/* GPLEV0's bit for the console's receive pin; false if unreadable. */
static bool
rx_level(uint32_t *level)
{
	uint32_t word;

	if (!erx_bcm2711_gpio_gplev0_read(gpio, &word))
		return (false);
	*level = erx_bcm2711_gpio_gplev0_lev_get(word) >> CONSOLE_RX_PIN & 1;
	return (true);
}

/*
 * Samples the console's receive pin until deadline, taking each byte the
 * console receives meanwhile, so its receiver never overruns; false if
 * GPLEV0 cannot be read.
 */
static bool
keys_sample(uint64_t deadline, key_sample_t *seen)
{
	uint32_t level, last;

	*seen = (key_sample_t){ 0 };
	if (!rx_level(&last))
		return (false);
	seen->first_level = last;
	while (erx_sysreg_cntpct_el0_read() < deadline) {
		if (!rx_level(&level))
			return (false);
		seen->samples++;
		if (level == 0)
			seen->low_samples++;
		if (level != last)
			seen->transitions++;
		last = level;
		if (take_byte())
			seen->bytes++;
	}
	return (true);
}

/* What the keys phase says of GPLEV0 and the console's receive pin. */
static const char *
keys_verdict(const key_sample_t *seen)
{
	if (seen->bytes == 0)
		return ("no byte received: undecided");
	return (seen->transitions > 0 ? "the bit follows the console's receive line" :
	    "the bit stayed steady while bytes arrived");
}

static void
keys_show(const key_sample_t *seen)
{
	line_start("keys pin ");
	put_dec(CONSOLE_RX_PIN);
	put_str(" samples ");
	put_dec(seen->samples);
	put_str(" bytes ");
	put_dec(seen->bytes);
	put_str(" first ");
	put_dec(seen->first_level);
	put_str(" low ");
	put_dec(seen->low_samples);
	put_str(" transitions ");
	put_dec(seen->transitions);
	line_end();
	line_start("keys verdict: ");
	put_str(keys_verdict(seen));
	line_end();
}

static void
wait_until(uint64_t deadline)
{
	while (erx_sysreg_cntpct_el0_read() < deadline)
		continue;
}

static void
stopped(const char *why)
{
	line_start("stopped: ");
	put_str(why);
	line_end();
}

void
header_probe(void)
{
	const uint64_t start = erx_sysreg_cntpct_el0_read();
	const uint64_t hz = erx_sysreg_cntfrq_el0_read();
	key_sample_t seen;

	line_end();
	line_start("erXos header probe " PROBE_REVISION);
	line_end();
	if (!registers_snapshot("boot")) {
		stopped("a register lies outside its window");
		return;
	}
	line_start("CNTFRQ_EL0 ");
	put_dec(hz);
	line_end();
	if (hz == 0) {
		stopped("CNTFRQ_EL0 is 0: no timed phase can run");
		return;
	}
	line_start("keys: type at the console now, for ");
	put_dec(KEY_SECONDS);
	put_str(" seconds");
	line_end();
	if (!keys_sample(erx_sysreg_cntpct_el0_read() + KEY_SECONDS * hz, &seen)) {
		stopped("GPLEV0 lies outside its window");
		return;
	}
	keys_show(&seen);
	line_start("waiting for the minute snapshot");
	line_end();
	wait_until(start + SNAPSHOT_SECONDS * hz);
	line_start("minute snapshot at ");
	put_dec((erx_sysreg_cntpct_el0_read() - start) / hz);
	put_str(" seconds after entry");
	line_end();
	if (!registers_snapshot("minute")) {
		stopped("a register lies outside its window");
		return;
	}
	line_start("done");
	line_end();
}
