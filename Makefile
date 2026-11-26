# make            builds iconservicesagent and iconservicesd for macOS (on the Mac: clang + the host frameworks)
# make check      the store.index tests (any POSIX host)
# On FreeBSD (pearOS): sh build-bsd.sh OUTDIR
CC ?= cc
OBJC = clang -fobjc-arc -Wall -O1
FW = -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO
all: iconservicesagent iconservicesd
iconservicesagent: agent/main.m common/store_index.c common/store_index.h
	$(OBJC) -o $@ agent/main.m common/store_index.c $(FW)
iconservicesd: daemon/main.m
	$(OBJC) -o $@ daemon/main.m -framework Foundation
check:
	$(CC) -O1 -Wall -o index_check test/index_check.c common/store_index.c && ./index_check; rc=$$?; rm -f index_check; exit $$rc
clean:
	rm -f iconservicesagent iconservicesd index_check
.PHONY: all check clean
