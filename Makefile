.PHONY: build warnings-as-errors swift-test selftest ui-test lifecycle-test check package package-dry verify-package run probe clean

build:
	swift build

warnings-as-errors:
	swift build -Xswiftc -warnings-as-errors

swift-test:
	swift test

selftest:
	swift run reserve-selftest

ui-test:
	swift run Reserve --self-test-ui

# Drives real state transitions through the live popover and Settings window:
# appearance changes with both surfaces open, and provider disclosure on screen.
lifecycle-test:
	swift run Reserve --self-test-lifecycle

check: warnings-as-errors swift-test selftest ui-test lifecycle-test

package:
	./Scripts/package_app.sh --mode local

# Builds the release shape (Universal 2 app, DMG, checksum) without using Apple
# credentials. Outputs live in the system temporary directory, not the repo.
package-dry:
	RESERVE_OUTPUT_DIR="$${TMPDIR:-/tmp}/reserve-package-dry" \
	RESERVE_OVERWRITE=1 ./Scripts/package_app.sh --mode dry-run

verify-package:
	./Scripts/verify_package.sh --mode local Reserve.app

run: package
	open Reserve.app

probe:
	swift run reserve-probe all

# Only SwiftPM output and the known, generated local app are removed.
clean:
	swift package clean
	rm -rf ./Reserve.app
