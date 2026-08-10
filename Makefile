PREFIX ?= /usr/local
SWIFTC ?= swiftc
MACOSX_DEPLOYMENT_TARGET ?= 14

all: kilx

kilx: main.swift
	$(SWIFTC) -O -target arm64-apple-macos$(MACOSX_DEPLOYMENT_TARGET) main.swift -o .kilx-arm64
	$(SWIFTC) -O -target x86_64-apple-macos$(MACOSX_DEPLOYMENT_TARGET) main.swift -o .kilx-x86_64
	lipo -create -output kilx .kilx-arm64 .kilx-x86_64
	rm -f .kilx-arm64 .kilx-x86_64

install: kilx
	install -d $(PREFIX)/bin
	install -m 755 kilx $(PREFIX)/bin/kilx

clean:
	rm -f kilx .kilx-arm64 .kilx-x86_64

.PHONY: all install clean
