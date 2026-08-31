PREFIX ?= /usr/local

.PHONY: build clean

build:
	swift build -c release
	sudo mkdir -p $(PREFIX)/bin
	sudo cp .build/release/retroscan $(PREFIX)/bin/retroscan
	@echo "installed: $(PREFIX)/bin/retroscan"

clean:
	swift package clean
