APP_NAME := Copaste
BUNDLE_ID := com.copaste.app
BUILD_DIR := .build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
DMG_STAGING := $(BUILD_DIR)/dmg
DMG_FILE := $(BUILD_DIR)/$(APP_NAME).dmg

.PHONY: all build bundle install run clean icon dmg

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
	codesign --force --deep --sign - $(APP_BUNDLE)
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
