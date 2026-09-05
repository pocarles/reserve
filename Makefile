.PHONY: build warnings-as-errors swift-test selftest ui-test lifecycle-test connection-test check package package-dry verify-package run probe clean

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

connection-test:
	swift run Reserve --self-test-connections

check: warnings-as-errors swift-test selftest ui-test lifecycle-test connection-test

package:
	./Scripts/package_app.sh --mode local

# Builds the release shape (Universal 2 app, DMG, checksum) without using Apple
# credentials. Outputs live in the system temporary directory, not the repo.
package-dry:
	RESERVE_OUTPUT_DIR="$${TMPDIR:-/tmp}/reserve-package-dry" \
	RESERVE_OVERWRITE=1 ./Scripts/package_app.sh --mode dry-run

verify-package:
	./Scripts/verify_package.sh --mode local Reserve.app

# `open` reuses an already-running app, even after its bundle was replaced.
# Stop only this checkout's exact packaged binary so `make run` always exercises
# the build it just produced.
run: package
	@binary="$(CURDIR)/Reserve.app/Contents/MacOS/Reserve"; \
	pids="$$(pgrep -f -x "$$binary" || true)"; \
	if [ -n "$$pids" ]; then kill -TERM $$pids; fi; \
	attempts=0; \
	while pgrep -f -x "$$binary" >/dev/null 2>&1 && [ $$attempts -lt 30 ]; do \
		sleep 0.1; attempts=$$((attempts + 1)); \
	done; \
	if pgrep -f -x "$$binary" >/dev/null 2>&1; then \
		echo "error: previous Reserve process did not exit" >&2; exit 1; \
	fi; \
	open "$(CURDIR)/Reserve.app"

probe:
	swift run reserve-probe all

# Only SwiftPM output and the known, generated local app are removed.
clean:
	swift package clean
	rm -rf ./Reserve.app
