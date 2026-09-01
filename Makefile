PREFIX ?= /usr/local
APP_DEST ?= /Applications

.PHONY: build app icon check clean

build:
	swift build -c release
	sudo mkdir -p $(PREFIX)/bin
	sudo cp .build/release/retroscan $(PREFIX)/bin/retroscan
	@echo "installed: $(PREFIX)/bin/retroscan"

# Assembles Retroscan.app around the RetroscanApp binary (SwiftPM can't
# produce app bundles itself) and installs it.
app:
	swift build -c release
	rm -rf .build/release/Retroscan.app
	mkdir -p .build/release/Retroscan.app/Contents/MacOS .build/release/Retroscan.app/Contents/Resources
	cp .build/release/RetroscanApp .build/release/Retroscan.app/Contents/MacOS/Retroscan
	cp Sources/RetroscanApp/Info.plist .build/release/Retroscan.app/Contents/Info.plist
	cp Sources/RetroscanApp/AppIcon.icns .build/release/Retroscan.app/Contents/Resources/AppIcon.icns
	codesign --force --sign - .build/release/Retroscan.app
	rm -rf $(APP_DEST)/Retroscan.app
	cp -R .build/release/Retroscan.app $(APP_DEST)/Retroscan.app
	@echo "installed: $(APP_DEST)/Retroscan.app"

# Regenerates the committed AppIcon.icns from the drawing code.
icon:
	swift Tools/make-icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o Sources/RetroscanApp/AppIcon.icns

# Self-check for the crop pipeline (synthetic pages, no scanner needed).
check:
	swift run retroscan-check

clean:
	swift package clean
