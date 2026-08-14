.PHONY: build test ui-test lifecycle-test check package run probe clean

build:
	swift build

test:
	swift run usagebar-selftest

ui-test:
	swift run UsageBar --self-test-ui

# Drives real state transitions through the live popover and Settings window:
# appearance changes with both surfaces open, and provider disclosure on screen.
lifecycle-test:
	swift run UsageBar --self-test-lifecycle

check: build test ui-test lifecycle-test

package:
	./Scripts/package_app.sh

run: package
	open Reserve.app

probe:
	swift run usagebar-probe all

clean:
	swift package clean
	rm -rf Reserve.app
