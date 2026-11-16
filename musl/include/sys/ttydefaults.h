/* Modified by erXos: termios follows FreeBSD's layout and modes, from abi/termios.txt. */
#ifndef _SYS_TTYDEFAULTS_H
#define _SYS_TTYDEFAULTS_H

#define TTYDEF_IFLAG (BRKINT | ICRNL | IMAXBEL | IXON | IXANY | IUTF8)
#define TTYDEF_OFLAG (OPOST | ONLCR)
#define TTYDEF_LFLAG_NOECHO (ICANON | ISIG | IEXTEN)
#define TTYDEF_LFLAG_ECHO (TTYDEF_LFLAG_NOECHO | ECHO | ECHOE | ECHOKE | ECHOCTL)
#define TTYDEF_LFLAG TTYDEF_LFLAG_ECHO
#define TTYDEF_CFLAG (CREAD | CS8 | HUPCL)
#define TTYDEF_SPEED (B9600)
#define CTRL(x) ((x)&037)
#define CEOF CTRL('d')

/* FreeBSD's (sys/sys/ttydefaults.h): CEOL is the disabled byte, 0xff. */
#define CEOL 0xff
#define CSTATUS CTRL('t')

#define CERASE 0177
#define CERASE2 CTRL('h')
#define CINTR CTRL('c')
#define CKILL CTRL('u')
#define CMIN 1
#define CQUIT 034
#define CSUSP CTRL('z')
#define CTIME 0
#define CDSUSP CTRL('y')
#define CSTART CTRL('q')
#define CSTOP CTRL('s')
#define CLNEXT CTRL('v')
#define CDISCARD CTRL('o')
#define CWERASE CTRL('w')
#define CREPRINT CTRL('r')
#define CEOT CEOF
#define CBRK CEOL
#define CRPRNT CREPRINT
#define CFLUSH CDISCARD

#endif
