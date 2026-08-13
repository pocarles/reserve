.PHONY: build test check package run probe clean

build:
	swift build

test:
	swift run usagebar-selftest

check: build test

package:
	./Scripts/package_app.sh

run: package
	open UsageBar.app

probe:
	swift run usagebar-probe all

clean:
	swift package clean
	rm -rf UsageBar.app
