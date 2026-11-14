/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A run queue's wakeup-other check (erl_process.c, wakeup_other_check and
 * wakeup_other_check_legacy). Each time a scheduler looks for its next job,
 * the queue's count grows with the backlog beside that job and the reductions
 * charged since the last look, and decays while there is no backlog; a count
 * past its limit wakes another scheduler. Pure: the caller reads the queue,
 * stores the count and does the waking.
 *
 * No input overflows. The charge is clamped to INT_MAX, which already passes
 * every limit, so with a queue length below 2^31 the arithmetic, in int64_t,
 * stays below 2^63. The stored count is bounded: the default check, which
 * every queue kind runs, keeps it within [0, limit], and the legacy check,
 * which only normal queues run, at or below INT_MAX.
 */

#ifndef ERL_WAKEUP_OTHER_H__
#define ERL_WAKEUP_OTHER_H__

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
	int count;	/* the queue's next wakeup_other */
	bool over;	/* the count passed its limit: wake another scheduler */
} ErtsWakeupOtherStep;

/*
 * The inputs of both checks: count, the queue's wakeup_other, is at least 0;
 * reds, the reductions charged to the queue since its last look, the sum of
 * the charges of every scheduler sharing it, is at least 0; and len is the
 * queue's length, the job just picked included.
 */
static inline int64_t
erts_wakeup_other_charge(int64_t reds)
{
	return (reds > INT_MAX ? INT_MAX : reds);
}

/*
 * The default check, with count within [0, limit]. A look with a backlog,
 * len - 1 jobs beside the one picked, adds the backlog times reds and inc;
 * one without takes reds times 2^dec_shift, dec_shift being one of the
 * thresholds' shifts, from -5 to 3. A normal queue's count returns to zero
 * when it passes its limit. A dirty queue's holds at the limit, so each later
 * look with a backlog wakes another waiting dirty scheduler until the backlog
 * clears, and its first look without one decays from the limit.
 */
static inline ErtsWakeupOtherStep
erts_wakeup_other_step(int count, int64_t reds, int len, int limit, int inc,
    int dec_shift, bool dirty)
{
	int64_t charge = erts_wakeup_other_charge(reds);
	int64_t left_len = (int64_t)len - 1;
	int64_t next;

	if (left_len < 1) {
		int64_t reduce = dec_shift >= 0 ? charge << dec_shift :
		    charge >> -dec_shift;
		next = count - reduce;
		return ((ErtsWakeupOtherStep){ next < 0 ? 0 : (int)next, false });
	}
	next = count + left_len * charge + inc;
	if (next <= limit)
		return ((ErtsWakeupOtherStep){ (int)next, false });
	return ((ErtsWakeupOtherStep){ dirty ? limit : 0, true });
}

/*
 * The legacy check. A look with len below 2 takes reds times dec. Otherwise
 * a count at or past its limit returns to zero and reports over, and one
 * below adds len times reds and inc, so a count pushed past its limit wakes
 * another scheduler at the next look with a backlog.
 */
static inline ErtsWakeupOtherStep
erts_wakeup_other_step_legacy(int count, int64_t reds, int len, int limit,
    int inc, int dec)
{
	int64_t charge = erts_wakeup_other_charge(reds);
	int64_t next;

	if (len < 2) {
		next = count - dec * charge;
		return ((ErtsWakeupOtherStep){ next < 0 ? 0 : (int)next, false });
	}
	if (count >= limit)
		return ((ErtsWakeupOtherStep){ 0, true });
	next = count + (int64_t)len * charge + inc;
	return ((ErtsWakeupOtherStep){ next > INT_MAX ? INT_MAX : (int)next,
	    false });
}

#endif
