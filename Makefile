APP_NAME := Copaste
BUNDLE_ID := com.copaste.app
BUILD_DIR := .build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
DMG_STAGING := $(BUILD_DIR)/dmg
DMG_FILE := $(BUILD_DIR)/$(APP_NAME).dmg

# Codesigning identity. Defaults to the self-signed cert created by
# `make setup-signing`. Looked up by SHA-1 hash so codesign doesn't require
# the cert to be trusted (which would need an admin password to set up).
# Falls back to ad-hoc ('-') if the cert isn't in the keychain.
# Override at the command line: `make dmg SIGN_IDENTITY=...`.
SELF_SIGNED_CN := Copaste Self-Signed
SELF_SIGNED_SHA := $(shell security find-certificate -c "$(SELF_SIGNED_CN)" -Z 2>/dev/null | awk -F': ' '/SHA-1/{gsub(/ /, "", $$2); print $$2; exit}')
SIGN_IDENTITY ?= $(if $(SELF_SIGNED_SHA),$(SELF_SIGNED_SHA),-)

.PHONY: all build bundle install run clean icon dmg setup-signing

all: bundle

build:
	swift build -c release

icon: Resources/AppIcon.icns

Resources/AppIcon.icns: tools/make_icon.swift
	swift tools/make_icon.swift
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

bundle: build icon
	@echo "→ Assembling $(APP_NAME).app"
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "→ Signing as: $(SIGN_IDENTITY)"
	codesign --force --deep --identifier $(BUNDLE_ID) --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)
	@echo "✓ Built $(APP_BUNDLE)"

install: bundle
	@echo "→ Installing to $(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "✓ Installed. Launch from Applications or run: open -a $(APP_NAME)"

run: bundle
	open $(APP_BUNDLE)

dmg: bundle
	@echo "→ Building $(DMG_FILE)"
	rm -rf $(DMG_STAGING) $(DMG_FILE)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_BUNDLE) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG_FILE)
	rm -rf $(DMG_STAGING)
	@echo "✓ Built $(DMG_FILE)"

clean:
	rm -rf $(BUILD_DIR)
	swift package clean

# One-time setup: create a self-signed code signing cert in your login
# keychain. After this, every `make dmg` signs with the same cert, so TCC
# permissions (Accessibility, etc.) survive across rebuilds.
setup-signing:
	@bash tools/setup-signing.sh
