PREFIX ?= /usr/local
SWIFTC ?= swiftc

all: kilx

kilx: main.swift
	$(SWIFTC) -O main.swift -o kilx

install: kilx
	install -d $(PREFIX)/bin
	install -m 755 kilx $(PREFIX)/bin/kilx

clean:
	rm -f kilx

.PHONY: all install clean
