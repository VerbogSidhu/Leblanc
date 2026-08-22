APP_NAME := Leblanc
SWIFT := swift
MOCK_CORE := build/mockcore.dylib

# The macOS 27 beta Command Line Tools ship without libSwiftUIMacros.dylib,
# which SwiftUI's macro-ified property wrappers (@State, @Environment, ...)
# require. Building against the bundled MacOSX26.sdk sidesteps the missing
# plugin (its SwiftUI still declares them as native property wrappers).
# Export your own SDKROOT to override; a real Xcode install needs none of this.
ifeq ($(origin SDKROOT),undefined)
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
SDKROOT := $(shell test -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk && echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk)
endif
endif
export SDKROOT

.PHONY: all build run app selftest scan-steam diagnose mock-core clean test watch-hid app-release

all: build

## Compile the Swift package (debug)
build:
	$(SWIFT) build

## Pure-logic unit assertions (VDFParser / RomTitle / PixelConverter / ids)
test: build
	$(SWIFT) run Leblanc --unit-test

## Headless HID watch (macOS 27 beta PS-capture experiment)
watch-hid: build
	$(SWIFT) run Leblanc --watch-hid 15

## Assemble a release .app bundle (smaller, faster binary)
app-release:
	$(SWIFT) build -c release
	./build-app.sh release

## Assemble GameDock.app and open it
run: app
	open build/Leblanc.app

## Assemble the .app bundle (debug binary)
app: build
	./build-app.sh debug

## Headless end-to-end emulator self-test (requires mock core)
selftest: build mock-core
	GAMEDOCK_CORE_PATH=$(MOCK_CORE) $(SWIFT) run Leblanc --selftest

## Dump the parsed Steam library (validates VDF/ACF parsing against a real install)
scan-steam: build
	$(SWIFT) run Leblanc --scan-steam

## Print connected controllers + their button inventory
diagnose: build
	$(SWIFT) run Leblanc --diagnose-input

## Build the fake libretro core used by --selftest
mock-core:
	mkdir -p build
	clang -O2 -fPIC -shared -o $(MOCK_CORE) Tests/MockCore/mockcore.c

clean:
	$(SWIFT) package clean
	rm -rf build
