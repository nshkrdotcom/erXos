# The SDK's hello program, built with the SDK alone: make SDK=DIR.
include $(SDK)/share/erxos/sdk.mk

bin/hello: hello.o
	mkdir -p bin
	$(ERX_LD) $(ERX_LDFLAGS) -o $@ hello.o $(ERX_LIBS)

hello.o: hello.c
	$(ERX_CC) $(ERX_CFLAGS) -Wall -Wextra -Werror -c hello.c -o $@
