/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The rest of the program layer that liberx/program/program.c names, for
 * test/fixtures/exec_release_driver.c, which runs only its erx_prog_enter:
 * each name aborts if it is ever called. The file includes no header, so
 * no prototype of liberx's meets these.
 */

#include <stdlib.h>

#define	STUB(name)	void name(void); void name(void) { abort(); }

STUB(erx_executor_slot)
STUB(erx_group_status)
STUB(erx_group_take_ready)
STUB(erx_irq_trigger)
STUB(erx_lane_reader_init)
STUB(erx_lane_side_bytes)
STUB(erx_lane_take)
STUB(erx_lane_take_armed)
STUB(erx_park)
STUB(erx_pipe_doorbell)
STUB(erx_pipe_report)
STUB(erx_prog_argv_next)
STUB(erx_prog_channel_buffer)
STUB(erx_prog_channel_frame)
STUB(erx_prog_channel_open)
STUB(erx_prog_channel_room)
STUB(erx_prog_env_next)
STUB(erx_prog_fd_setup)
STUB(erx_prog_inbound_open)
STUB(erx_prog_object_map)
STUB(erx_prog_page_round)
STUB(erx_prog_pages_give)
STUB(erx_prog_pages_take)
STUB(erx_prog_scratch_bytes)
STUB(erx_prog_sig_start)
STUB(erx_prog_startup_plan)
STUB(erx_pthread_create_executor)
STUB(erx_umtx_wait)
STUB(erx_umtx_wake)
STUB(erx_utcb_self)
