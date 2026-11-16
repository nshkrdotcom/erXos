#define _BSD_SOURCE
#include <termios.h>

/* Both speeds, as FreeBSD's cfsetspeed sets them (lib/libc/gen/termios.c). */
int cfsetspeed(struct termios *tio, speed_t speed)
{
	tio->c_ispeed = tio->c_ospeed = speed;
	return 0;
}
