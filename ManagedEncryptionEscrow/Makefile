#!/usr/bin/make -f
#
# Managed Encryption Escrow build
# Builds the app bundle into build/pkg-root. It has no installer of its own:
# Crypt's package ships the app, the helper and the helper's LaunchDaemon
# (Package/build-unsigned-pkg.sh). With SIGNING_IDENTITY_APP set it signs the
# helper and the app; without it they stay unsigned, as the public release
# does. An unsigned helper refuses every client by design.
#

-include .env
export

# One build stamp, YYYY.MM.DD.HHMM, split for the About box as 2026.10.06 (1342).
VERSION := $(or $(VERSION),$(shell date '+%Y.%m.%d.%H%M'))
MARKETING_VERSION := $(shell echo $(VERSION) | sed 's/\.[^.]*$$//')
BUILD_NUMBER := $(shell echo $(VERSION) | sed 's/.*\.//')

BUILD_DIR = build
PKG_ROOT = $(BUILD_DIR)/pkg-root
APP_BUNDLE_PATH = Applications/Utilities/Managed Encryption Escrow.app
APP_CONTENTS = $(PKG_ROOT)/$(APP_BUNDLE_PATH)/Contents
GUI_BINARY_NAME = ManagedEncryptionEscrow
HELPER_BINARY_NAME = ManagedEncryptionEscrowHelper
HELPER_LABEL = com.grahamgilbert.crypt.helper
APP_IDENTIFIER = com.grahamgilbert.crypt.gui

# The output path differs between toolchains, so ask SwiftPM for it.
SWIFT_BUILD_DIR = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

# The app icon is an Icon Composer bundle. actool compiles it into Assets.car,
# which holds the macOS 26 icon with its light and dark appearances, and a
# composited .icns for older macOS. An actool older than Xcode 27's drops the
# appearance stacks without an error, so the build finds Xcode 27 and refuses
# to go on without it. Set XCODE_27 to the Xcode app to use a specific one.
ICON_NAME = ManagedEncryptionEscrow
ICON_SOURCE = Resources/$(ICON_NAME).icon
ICON_BUILD_DIR = $(BUILD_DIR)/actool-out

.PHONY: all build test icon app verify clean

all: app

# Record the SDK the binaries are linked against. Some toolchains write the
# deployment target as the SDK version, and AppKit then keeps the pre-macOS 26
# window chrome (a title bar plus a small tab strip) instead of the toolbar tabs.
SDK_VERSION := $(shell xcrun --show-sdk-version)
# The version is stamped after linking with vtool, because linker flags passed
# through a universal SwiftPM build reach clang without -Xlinker on some Xcodes.
DEPLOYMENT_TARGET = 14.0

build:
	swift build -c release --arch arm64 --arch x86_64

test:
	swift test

icon:
	@set -e; dev=""; \
	for xc in "$(XCODE_27)" /Applications/Xcode_27.app /Applications/Xcode_27.*.app \
		"$$(xcode-select -p 2>/dev/null | sed 's|/Contents/Developer$$||')" /Applications/Xcode.app; do \
		[ -n "$$xc" ] && [ -d "$$xc/Contents/Developer" ] || continue; \
		ver=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$xc/Contents/Info.plist" 2>/dev/null || true); \
		if [ "$${ver%%.*}" -ge 27 ] 2>/dev/null; then dev="$$xc/Contents/Developer"; break; fi; \
	done; \
	if [ -z "$$dev" ]; then \
		echo "error: the app icon needs actool from Xcode 27 or later; none found." >&2; \
		echo "Install Xcode 27, select it with xcode-select, or set XCODE_27=/path/to/Xcode.app." >&2; \
		exit 1; \
	fi; \
	[ -d "$(ICON_SOURCE)" ] || { echo "error: icon bundle not found at $(ICON_SOURCE)" >&2; exit 1; }; \
	rm -rf "$(ICON_BUILD_DIR)"; mkdir -p "$(ICON_BUILD_DIR)" "$(APP_CONTENTS)/Resources"; \
	echo "Compiling $(ICON_SOURCE) with actool from $$dev"; \
	DEVELOPER_DIR="$$dev" xcrun actool \
		--compile "$(ICON_BUILD_DIR)" \
		--platform macosx \
		--minimum-deployment-target $(DEPLOYMENT_TARGET) \
		--app-icon "$(ICON_NAME)" \
		--output-partial-info-plist "$(ICON_BUILD_DIR)/partial-info.plist" \
		--warnings --errors \
		"$(ICON_SOURCE)" > /dev/null; \
	for out in Assets.car "$(ICON_NAME).icns"; do \
		[ -f "$(ICON_BUILD_DIR)/$$out" ] || { echo "error: actool did not produce $$out" >&2; exit 1; }; \
		cp "$(ICON_BUILD_DIR)/$$out" "$(APP_CONTENTS)/Resources/$$out"; \
	done

app: build
	@rm -rf "$(PKG_ROOT)"
	@mkdir -p "$(APP_CONTENTS)/MacOS" "$(APP_CONTENTS)/Resources"
	@cp "$(SWIFT_BUILD_DIR)/ManagedEncryptionEscrowApp" "$(APP_CONTENTS)/MacOS/$(GUI_BINARY_NAME)"
	@cp "$(SWIFT_BUILD_DIR)/ManagedEncryptionEscrowHelper" "$(APP_CONTENTS)/MacOS/$(HELPER_BINARY_NAME)"
	@chmod 755 "$(APP_CONTENTS)/MacOS/"*
	@for bin in "$(APP_CONTENTS)/MacOS/"*; do \
		vtool -set-build-version macos $(DEPLOYMENT_TARGET) $(SDK_VERSION) -replace -output "$$bin.stamped" "$$bin" && \
		mv "$$bin.stamped" "$$bin" && codesign --force --sign - "$$bin" 2>/dev/null; \
	done
	@sed -e 's/{{MARKETING_VERSION}}/$(MARKETING_VERSION)/g' \
	     -e 's/{{BUILD_NUMBER}}/$(BUILD_NUMBER)/g' \
	     packaging/resources/Info.plist.template > "$(APP_CONTENTS)/Info.plist"
	@$(MAKE) --no-print-directory icon
ifneq ($(SIGNING_IDENTITY_APP),)
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" --options runtime --timestamp \
		--identifier $(HELPER_LABEL) "$(APP_CONTENTS)/MacOS/$(HELPER_BINARY_NAME)"
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" --options runtime --timestamp \
		--identifier $(APP_IDENTIFIER) "$(PKG_ROOT)/$(APP_BUNDLE_PATH)"
	@echo "Signed app bundle"
else
	@echo "SIGNING_IDENTITY_APP not set: app bundle left unsigned"
endif

verify:
	@codesign --verify --strict --verbose=2 "$(PKG_ROOT)/$(APP_BUNDLE_PATH)"
	@codesign -dr - "$(APP_CONTENTS)/MacOS/$(HELPER_BINARY_NAME)"

clean:
	@rm -rf $(BUILD_DIR) .build
