# Use the installed Xcode without changing the global developer directory.
DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: test build app run xcode-test plugin

test:
	swift test

build:
	swift build -c release

app: build
	./scripts/package-app.sh

run: app
	open .build/ScheduleBar.app

plugin: build
	mkdir -p Plugins/schedulebar/bin
	cp .build/release/schedulebar-mcp Plugins/schedulebar/bin/schedulebar-mcp

xcode-test:
	xcodebuild -scheme ScheduleBar-Package \
		-destination 'platform=macOS' \
		-derivedDataPath .derived \
		test
