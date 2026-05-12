APP_NAME  ?= GimbalController
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   = $(APP_BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS

.PHONY: all clean run test harness

all:
	swift build -c release --product $(APP_NAME)
	mkdir -p $(MACOS_DIR) $(CONTENTS)
	cp .build/release/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS)/Info.plist
	codesign --force --deep --sign - \
		--entitlements GimbalController.entitlements \
		$(APP_BUNDLE)
	mkdir -p ~/Applications
	rm -rf ~/Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) ~/Applications/$(APP_NAME).app

run: all
	open $(APP_BUNDLE)

test:
	swift test

harness:
	swift build -c release --product JournalHarness
	@if [ -z "$(VIDEO)" ]; then echo "Usage: make harness VIDEO=/path/to/clip.mov"; exit 1; fi
	.build/release/JournalHarness "$(VIDEO)"

clean:
	rm -rf $(BUILD_DIR) .build
