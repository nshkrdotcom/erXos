#include <termios.h>

/* FreeBSD's struct termios holds each speed as its rate, in its own member. */
speed_t cfgetospeed(const struct termios *tio)
{
	return tio->c_ospeed;
}

speed_t cfgetispeed(const struct termios *tio)
{
	return tio->c_ispeed;
}
