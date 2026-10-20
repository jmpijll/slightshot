# Build, sign and release Slightshot.
#
# Everything runs through Swift Package Manager plus the scripts in Scripts/,
# so no Xcode project file needs to be kept in sync.

SHELL := /bin/bash
VERSION ?= $(or $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'),0.0.0)
APP := build/Slightshot.app
DMG := build/Slightshot-$(VERSION).dmg

.PHONY: help build run app dmg notarize release icon lint test clean

help:
	@echo "make build       debug build"
	@echo "make run         build and launch the app bundle"
	@echo "make app         build and sign Slightshot.app for version $(VERSION)"
	@echo "make dmg         build the signed disk image"
	@echo "make notarize    notarise and staple the disk image"
	@echo "make release     app + dmg + notarize"
	@echo "make icon        regenerate app, menu bar and README artwork"
	@echo "make test        verify annotation rendering and video export"
	@echo "make lint        run SwiftLint in strict mode"
	@echo "make clean       remove build artefacts"

build:
	swift build

app:
	VERSION=$(VERSION) ./Scripts/bundle.sh

run: app
	open $(APP)

dmg: app
	VERSION=$(VERSION) ./Scripts/make_dmg.sh

notarize:
	./Scripts/notarize.sh $(DMG)

release: app
	./Scripts/notarize.sh $(APP)
	VERSION=$(VERSION) ./Scripts/make_dmg.sh
	./Scripts/notarize.sh $(DMG)
	@echo "==> $(DMG) is ready to publish"

icon:
	@rm -rf build/AppIcon.iconset
	@mkdir -p build
	swift Scripts/make_icon.swift build/AppIcon.iconset
	iconutil -c icns -o Resources/AppIcon.icns build/AppIcon.iconset
	@rm -rf build/AppIcon.iconset
	@echo "==> Wrote Resources/AppIcon.icns"

test:
	swift test

lint:
	@if command -v swiftlint > /dev/null; then swiftlint --strict --quiet; else echo "swiftlint not installed; skipping"; fi

clean:
	swift package clean
	rm -rf build .build
