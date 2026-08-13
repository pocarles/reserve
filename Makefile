.PHONY: build test ui-test check package run probe clean

build:
	swift build

test:
	swift run usagebar-selftest

ui-test:
	swift run UsageBar --self-test-ui

check: build test ui-test

package:
	./Scripts/package_app.sh

run: package
	open UsageBar.app

probe:
	swift run usagebar-probe all

clean:
	swift package clean
	rm -rf UsageBar.app
