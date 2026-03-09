APP_NAME ?= GimbalController
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS

SOURCES = $(shell find Sources -name '*.swift')
ARCH ?= $(shell uname -m)

SDK = $(shell xcrun --show-sdk-path)
TARGET = $(ARCH)-apple-macosx14.0
SWIFT_FLAGS = \
	-parse-as-library \
	-sdk $(SDK) \
	-target $(TARGET) \
	-framework CoreBluetooth

TEST_SOURCES = $(shell find Tests/ProtocolTests -name '*.swift' 2>/dev/null)
PROTOCOL_SOURCES = $(shell find Sources/Protocol -name '*.swift')

.PHONY: all clean run test

all: $(MACOS_DIR)/$(APP_NAME) bundle-info

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(MACOS_DIR)/$(APP_NAME): $(SOURCES) | $(BUILD_DIR)
	mkdir -p $(MACOS_DIR)
	swiftc $(SWIFT_FLAGS) $(SOURCES) -o $@

bundle-info: | $(BUILD_DIR)
	mkdir -p $(CONTENTS)
	cp Info.plist $(CONTENTS)/Info.plist

run: all
	open $(APP_BUNDLE)

test: $(BUILD_DIR)
	swiftc -parse-as-library -sdk $(SDK) -target $(TARGET) \
		$(PROTOCOL_SOURCES) Tests/run_tests.swift \
		-o $(BUILD_DIR)/ProtocolTests
	$(BUILD_DIR)/ProtocolTests

clean:
	rm -rf $(BUILD_DIR) .build
