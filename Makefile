APP_NAME  := ClaudeIsland
BUNDLE_ID := io.github.joannemiki57.claudeisland
VERSION   := 1.1.0
MIN_MACOS := 13.0

BUILD := build
APP   := $(BUILD)/$(APP_NAME).app
BIN   := $(APP)/Contents/MacOS/$(APP_NAME)
SRC   := Sources/ClaudeIsland.swift
DEST  := /Applications/$(APP_NAME).app
ICON_PNG := Resources/icon/icon_1024.png
ICONSET  := $(BUILD)/AppIcon.iconset
ICNS     := $(BUILD)/AppIcon.icns

SWIFTC := swiftc -O -swift-version 5 -framework AppKit -framework SwiftUI

.PHONY: all build run demo install login unlogin uninstall zip clean icon

all: build

build: $(BIN)

# Regenerate the artwork with `make icon` after editing make_icon.swift.
icon:
	cd Resources/icon && swift make_icon.swift icon_1024.png clay

$(ICNS): $(ICON_PNG)
	@mkdir -p $(ICONSET)
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(ICON_PNG) --out $(ICONSET)/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s * 2)); sips -z $$d $$d $(ICON_PNG) --out $(ICONSET)/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONSET) -o $(ICNS)

$(BIN): $(SRC) $(ICNS) Makefile Resources/Info.plist
	@mkdir -p $(BUILD) $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	$(SWIFTC) -target arm64-apple-macos$(MIN_MACOS) -o $(BUILD)/$(APP_NAME)-arm64 $(SRC)
	$(SWIFTC) -target x86_64-apple-macos$(MIN_MACOS) -o $(BUILD)/$(APP_NAME)-x86_64 $(SRC)
	lipo -create -output $(BIN) $(BUILD)/$(APP_NAME)-arm64 $(BUILD)/$(APP_NAME)-x86_64
	@rm -f $(BUILD)/$(APP_NAME)-arm64 $(BUILD)/$(APP_NAME)-x86_64
	@sed -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/' -e 's/@VERSION@/$(VERSION)/' -e 's/@MIN_MACOS@/$(MIN_MACOS)/' \
		Resources/Info.plist > $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: build
	-@pkill -x $(APP_NAME); sleep 0.3
	open $(APP)

demo: build
	-@pkill -x $(APP_NAME); sleep 0.3
	open $(APP) --args --demo

install: build
	-@pkill -x $(APP_NAME); sleep 0.3
	rm -rf $(DEST)
	cp -R $(APP) $(DEST)
	open $(DEST)
	@echo "Installed to $(DEST)"

login:
	@osascript -e 'tell application "System Events" to delete (every login item whose name is "$(APP_NAME)")' >/dev/null 2>&1 || true
	@osascript -e 'tell application "System Events" to make login item at end with properties {path:"$(DEST)", hidden:false}' >/dev/null
	@echo "$(APP_NAME) will start at login."

unlogin:
	@osascript -e 'tell application "System Events" to delete (every login item whose name is "$(APP_NAME)")' >/dev/null 2>&1 || true
	@echo "Removed from login items."

uninstall: unlogin
	-@pkill -x $(APP_NAME)
	rm -rf $(DEST)
	-@defaults delete $(BUNDLE_ID) >/dev/null 2>&1
	@echo "Uninstalled."

zip: build
	cd $(BUILD) && rm -f $(APP_NAME)-$(VERSION).zip && ditto -c -k --norsrc --noextattr --noacl --keepParent $(APP_NAME).app $(APP_NAME)-$(VERSION).zip
	@echo "$(BUILD)/$(APP_NAME)-$(VERSION).zip"

clean:
	rm -rf $(BUILD)
