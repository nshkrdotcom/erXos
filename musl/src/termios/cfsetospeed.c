#include <termios.h>

/* Any rate is a speed, as FreeBSD's cfsetospeed takes it (lib/libc/gen/termios.c). */
int cfsetospeed(struct termios *tio, speed_t speed)
{
	tio->c_ospeed = speed;
	return 0;
}

int cfsetispeed(struct termios *tio, speed_t speed)
{
	tio->c_ispeed = speed;
	return 0;
}
