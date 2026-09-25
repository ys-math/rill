CONFIG     ?= release
APP        := build/Rill.app
APPS_DIR   ?= /Applications
BIN_DIR    ?= $(HOME)/.local/bin
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all build test app install uninstall run clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

# Assemble Rill.app from the SwiftPM products. The CLI ships inside the bundle so the
# installed symlink always matches the installed app.
app: build
	$(eval BIN := $(shell swift build -c $(CONFIG) --show-bin-path))
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN)/RillApp $(BIN)/rill $(APP)/Contents/MacOS/
	codesign --force --sign - $(APP)

install: app
	rm -rf $(APPS_DIR)/Rill.app
	cp -R $(APP) $(APPS_DIR)/
	$(LSREGISTER) -f $(APPS_DIR)/Rill.app
	mkdir -p $(BIN_DIR)
	ln -sf $(APPS_DIR)/Rill.app/Contents/MacOS/rill $(BIN_DIR)/rill

uninstall:
	rm -rf $(APPS_DIR)/Rill.app
	rm -f $(BIN_DIR)/rill

run: app
	open $(APP)

clean:
	rm -rf .build build
