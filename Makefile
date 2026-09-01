PREFIX ?= /usr/local
APP_DEST ?= /Applications
BUNDLE = .build/release/Retroscan.app
# Which binary goes inside the bundle. The release workflow overrides it with
# the universal one.
BIN ?= .build/release/RetroscanApp

.PHONY: build app bundle universal icon check clean

build:
	swift build -c release
	sudo mkdir -p $(PREFIX)/bin
	sudo cp .build/release/retroscan $(PREFIX)/bin/retroscan
	@echo "installed: $(PREFIX)/bin/retroscan"

# Assembles Retroscan.app around $(BIN) — SwiftPM cannot produce app bundles
# itself. The ad-hoc signature is enough to run the app on the machine that
# built it; a download needs a Developer ID (see .github/workflows/release.yml).
bundle:
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/Retroscan
	cp Sources/RetroscanApp/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Sources/RetroscanApp/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

# A binary that runs on Apple Silicon and Intel alike. Two SwiftPM builds and
# lipo, rather than `--arch arm64 --arch x86_64`, which needs a full Xcode
# install and so fails on Command Line Tools alone.
universal:
	swift build -c release --triple arm64-apple-macosx --product RetroscanApp
	swift build -c release --triple x86_64-apple-macosx --product RetroscanApp
	mkdir -p .build/universal
	lipo -create -output .build/universal/RetroscanApp \
		.build/arm64-apple-macosx/release/RetroscanApp \
		.build/x86_64-apple-macosx/release/RetroscanApp

# Builds the app for this Mac and installs it.
app:
	swift build -c release --product RetroscanApp
	$(MAKE) bundle
	rm -rf $(APP_DEST)/Retroscan.app
	cp -R $(BUNDLE) $(APP_DEST)/Retroscan.app
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
