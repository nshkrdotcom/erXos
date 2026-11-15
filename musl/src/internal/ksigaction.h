/*
 * Modified by erXos: the mask is _NSIG/8 bytes, the size every caller copies,
 * where it held Linux's 8; the assertions pin that size and the two words of
 * signals musl's set code (sigfillset, block.c) handles.
 */
#include <features.h>
#include <signal.h>

/* This is the structure used for the rt_sigaction syscall on most archs,
 * but it can be overridden by a file with the same name in the top-level
 * arch dir for a given arch, if necessary. */
struct k_sigaction {
	void (*handler)(int);
	unsigned long flags;
#ifdef SA_RESTORER
	void (*restorer)(void);
#endif
	unsigned mask[_NSIG / (8 * sizeof(unsigned))];
#ifndef SA_RESTORER
	void *unused;
#endif
};

_Static_assert(sizeof(((struct k_sigaction *)0)->mask) == _NSIG / 8,
    "k_sigaction's mask is the _NSIG/8 bytes its callers copy");
_Static_assert(_NSIG / 8 == 2 * sizeof(unsigned long),
    "musl's set code handles two words of signals");

hidden void __restore(), __restore_rt();
