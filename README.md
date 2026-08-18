# Reserve

Reserve is a native macOS menu-bar app that shows how much subscription
capacity remains in OpenAI Codex, Anthropic Claude, and Grok, when each window
resets, and whether the current pace is likely to last.

Learn more at [pocarles.com/reserve](https://pocarles.com/reserve/).

It is deliberately small: no Reserve account, browser automation, WebView,
cookie extraction, telemetry, crash reporting, cloud service, or third-party
status aggregator. Reserve uses Sparkle only for signed, user-approved macOS
updates.

## Install

Reserve requires macOS 14 or newer and is distributed as a signed, notarized
Universal 2 app for Apple silicon and Intel Macs.

1. Download [`Reserve.dmg`](https://github.com/pocarles/reserve/releases/latest/download/Reserve.dmg)
   and [`Reserve.dmg.sha256`](https://github.com/pocarles/reserve/releases/latest/download/Reserve.dmg.sha256).
2. In Terminal, verify the download from its directory:

   ```sh
   shasum -a 256 -c Reserve.dmg.sha256
   ```

3. Open the DMG and drag Reserve to Applications.

This manual step is required for the first Sparkle-enabled release. After that,
Reserve checks once a day by default and presents an **Install Update** button
when a newer signed release is available. It never installs silently.

Release assets are produced only by the protected GitHub release workflow. A
source build is ad-hoc signed and is intended only for the Mac that built it.

## Provider requirements

Reserve reuses sign-ins belonging to the official provider CLIs. It does not
create another account or copy credentials into its own storage.

Installation never asks for Claude access. If Claude protects its sign-in with
macOS, Reserve first shows a **Show limits** action and explains why access is
needed. The macOS prompt appears only after that action is confirmed.

- `codex`, signed into an OpenAI subscription;
- `claude`, signed into an Anthropic subscription;
- Grok Build 1.0.0 or newer, authenticated with `grok login`.

If a CLI is absent or signed out, Reserve reports that state. A Connect action
runs the provider's official login command and restricts browser handoff URLs to
that provider's expected HTTPS hosts. Temporary login output stays in memory.

Anthropic's subscription-usage endpoint is not a documented public API and may
change or rate-limit Reserve without notice. Grok Build 1.x does not expose its
billing method through ACP, so Reserve reads the authenticated billing endpoint
used by the CLI. OpenAI limits come from Codex app-server JSON-RPC. Provider
changes can temporarily break a refresh even when the local app is healthy;
the last valid snapshot remains visible and is marked stale.

## Build from source

Swift 6 and the current Apple Command Line Tools are enough to build and run
the app locally:

```sh
git clone https://github.com/pocarles/reserve.git
cd reserve
make run
```

`make run` builds and ad-hoc signs `Reserve.app`, then opens it. Do not
redistribute that generated app: it is neither Developer ID signed nor
notarized. The complete test gate and Universal 2 packaging dry run require
full Xcode:

```sh
make check
make package-dry
```

Useful developer commands:

```sh
make build
make swift-test
make selftest
make ui-test
make lifecycle-test
swift run reserve-probe openai
swift run reserve-probe anthropic
swift run reserve-probe grok
swift run reserve-probe local
```

The probe prints snapshots and errors, never credential material. The
Anthropic probe honors the same explicit Keychain-consent setting as the app.

## What Reserve shows

Every allowance uses the same projection model: reserve, on pace, deficit,
exhausted, stale, or unknown. Provider cards combine remaining capacity, reset
time, progress, pace marker, and a short projection. Five-hour windows stay
secondary to plan-level allowances. Grok's Build and Chat shares are shown as
components of its shared weekly pool, not as extra quota.

The optional savings view is an API-equivalent estimate, not a provider bill.
OpenAI and Anthropic use the observed input/cache/output mix when available;
Grok exposes an aggregate token count, so its comparison is approximate.
Subscription prices remain user-editable.

Service-health labels come from the providers' official status sources. The
default notification stream reports state transitions such as deficit,
exhaustion, recovery, stale data, and incidents. Fixed thresholds, renewal
notices, reset notices, and sounds are optional.

The menu-bar item can follow the most constrained enabled provider or remain
pinned to one provider. Reserve checks its signed update feed once a day by
default. Sparkle verifies the update's Ed25519 signature and Apple Developer ID
signature, then offers a familiar macOS install button. Checks send no system
profile or analytics, and can be disabled in Settings > About.

## Privacy and storage

Reserve keeps aggregate caches under:

```text
~/Library/Application Support/Reserve/snapshots.json
~/Library/Application Support/Reserve/local-usage-index.json
```

Preferences use the `com.pocarles.reserve` defaults domain. On the first v1
launch, Reserve can copy a fixed allowlist of preferences and validated cache
data from the former UsageBar locations. It never migrates credentials, raw
provider responses, paths, prompts, transcripts, or session records. Migration
is idempotent; invalid legacy data is left untouched and Reserve starts with a
clean new store.

The snapshot cache is capped at 100 KB. The local index is capped at 12 MB and
contains daily token/cost aggregates plus hashed file keys and byte offsets for
incremental scans. OAuth tokens, account identifiers, local paths, prompts,
responses, cookies, authorization headers, raw provider payloads, and process
logs are never cached.

Local totals come from session logs under `~/.claude/projects`,
`~/.codex/sessions`, and `~/.grok/sessions`; only bounded daily aggregates are
retained. Reserve may read `~/.claude/.credentials.json` and
`~/.grok/auth.json` when present. Claude Code can instead keep its sign-in in
Keychain; Reserve reads it only after the user chooses **Show limits**, through
Security.framework, and retains it in memory only. A current protected sign-in
takes precedence over legacy credential files left behind by Claude Code.

See [SECURITY.md](SECURITY.md) for reporting and support policy.

## Resource contract

- provider-limit refresh: configurable from 1 to 30 minutes;
- official service health: no more than once every 10 minutes;
- local aggregate scan: every 30 minutes or on manual refresh;
- signed update feed: once every 24 hours, with no system profile attached;
- scheduled work is skipped in Low Power Mode;
- wake/activation refreshes only data that is due;
- provider subprocess calls have deadlines, and descendant-held pipes cannot
  extend those deadlines;
- network bodies, streams, process output, local files, records, allocations,
  counters, cache sizes, backoff, and notification identifiers are bounded;
- target idle CPU: below 0.2% in a 30-minute packaged-release sample;
- target physical footprint: below 80 MB in that sample.

Those CPU and memory targets are release gates, not promises for every provider
CLI or Mac configuration.

## Architecture

```text
AppKit NSStatusItem + NSPopover
             |
        native dashboard
             |
         UsageStore
       /      |       \
  cache   local scan   providers
                       /   |   \
                  Codex Claude Grok
                   RPC  HTTPS HTTPS
```

`ReserveCore` owns provider, cache, scanner, and notification-domain behavior.
The `Reserve` executable owns AppKit surfaces and orchestration. The repository
also contains `reserve-probe`, `reserve-selftest`, and a standard SwiftPM test
target.

## Troubleshooting

**A provider says it is disconnected.** Run that provider CLI in Terminal and
complete its official login. Then use Refresh in Reserve.

**Claude is connected in the CLI but not Reserve.** If Claude Code stores its
credential with macOS, choose **Show limits** on the Claude card. Reserve
explains the one-time approval before macOS asks. You can turn it off later
under Settings > Providers.

**Data is stale or rate limited.** Reserve keeps the last valid snapshot and
retries after a bounded backoff. Check the provider's linked official status
page before reconnecting.

**A source-built app is blocked on another Mac.** Build it on that Mac or use
the signed and notarized DMG from GitHub Releases. Ad-hoc builds are not
portable.

**The checksum fails.** Delete both downloads and retrieve them again from the
same GitHub Release. Do not open the DMG.

## Contributing and release process

Focused contributions that improve the lightweight three-provider product are
welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md). Maintainer release operations
are documented in [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## Independence and trademarks

Reserve is an independent open-source project. It is not affiliated with,
endorsed by, sponsored by, or an official product of OpenAI, Anthropic, or xAI.
Provider names and marks belong to their respective owners. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. Copyright © 2026 Pierre-Olivier Carles. See [LICENSE](LICENSE).
