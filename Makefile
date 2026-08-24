# Use the installed Xcode without changing the global developer directory.
DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: test build app run xcode-test plugin verify-app plugin-preview plugin-install plugin-uninstall

test:
	swift test

build:
	swift build -c release

app: plugin
	./scripts/package-app.sh

verify-app: app
	codesign --verify --deep --strict --verbose=2 .build/ScheduleBar.app

run: app
	open .build/ScheduleBar.app

plugin: build
	mkdir -p Plugins/schedulebar/bin
	cp .build/release/schedulebar-mcp Plugins/schedulebar/bin/schedulebar-mcp

# These targets intentionally modify the current user's Codex plugin registry.
# They are never run as part of build/test/app packaging.
plugin-preview: plugin
	./scripts/preview-plugin-install.sh

plugin-install: plugin
	./scripts/install-plugin.sh

plugin-uninstall:
	./scripts/uninstall-plugin.sh

xcode-test:
	xcodebuild -scheme ScheduleBar-Package \
		-destination 'platform=macOS' \
		-derivedDataPath .derived \
		test
