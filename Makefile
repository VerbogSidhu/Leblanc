APP_NAME := Leblanc
SWIFT := swift
MOCK_CORE := build/mockcore.dylib

.PHONY: all build run app selftest scan-steam diagnose mock-core clean test

all: build

## Compile the Swift package (debug)
build:
	$(SWIFT) build

## Pure-logic unit assertions (VDFParser / RomTitle / PixelConverter / ids)
test: build
	$(SWIFT) run Leblanc --unit-test

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
