PREFIX ?= /usr/local
SWIFTC ?= swiftc

all: mkill

mkill: main.swift
	$(SWIFTC) -O main.swift -o mkill

install: mkill
	install -d $(PREFIX)/bin
	install -m 755 mkill $(PREFIX)/bin/mkill

clean:
	rm -f mkill

.PHONY: all install clean
