APP_NAME  ?= GimbalController
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   = $(APP_BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS

.PHONY: all clean run test

all:
	swift build -c release
	mkdir -p $(MACOS_DIR) $(CONTENTS)
	cp .build/release/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS)/Info.plist
	codesign --force --deep --sign - \
		--entitlements GimbalController.entitlements \
		$(APP_BUNDLE)

run: all
	open $(APP_BUNDLE)

test:
	swift test

clean:
	rm -rf $(BUILD_DIR) .build
