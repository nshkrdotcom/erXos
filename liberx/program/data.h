/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_DATA_H
#define LIBERX_PROGRAM_DATA_H

/*
 * The program's data area (docs/design-programs.md, "Reads and writes";
 * docs/design-files.md, "Native clients: liberx's file client"): the
 * memory object the session mapped into the program at its start, which
 * program.c maps read-write before main and keeps in erx_prog_self.  It
 * holds data_bytes / ERX_PROG_DATA_SLOT_BYTES slots, 1 to
 * ERX_PROG_DATA_SLOTS_MAX, through which the bytes of a file request move.
 * A request takes a free slot, names it, and gives it back once it has
 * copied the reply's bytes out or the request is over; a thread that finds
 * every slot taken waits for one, so a program's data requests in flight
 * are bounded by its slots.  One lock guards which slots are taken and is
 * never held across a wait.  Only workers take slots, after main is
 * called; the event executor never does.
 */

#include <stdint.h>

#include <erx/abi.h>

/* A free slot's number, taken for the caller, waiting while every slot is taken. */
uint32_t	erx_prog_data_take(void);
/* Gives back a slot erx_prog_data_take took, waking a thread that waits for one. */
void	erx_prog_data_give(uint32_t slot);
/* The ERX_PROG_DATA_SLOT_BYTES bytes of a slot the caller took. */
void	*erx_prog_data_bytes(uint32_t slot);

#endif /* !LIBERX_PROGRAM_DATA_H */
