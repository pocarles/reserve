# Reserve

Reserve is a native macOS menu-bar app that shows reported subscription
capacity for OpenAI Codex, Anthropic Claude, Grok, Cursor, Windsurf, and Copilot.
Optional insights show provider-reported account activity or activity from this Mac.
Windsurf uses usage saved by the official Devin Desktop app. Copilot support is
experimental and still needs an authenticated release check.

It is deliberately small: no Reserve account, browser automation, WebView,
cookie extraction, telemetry, crash reporting, cloud service, or third-party
status aggregator. Reserve uses Sparkle only for signed, user-approved macOS
updates.

## Install

Reserve requires macOS 14 or newer and is distributed as a signed, notarized
Universal 2 app for Apple silicon and Intel Macs.

1. Download [`Reserve.dmg`](https://github.com/pocarles/reserve/releases/latest/download/Reserve.dmg).
2. Open the DMG and drag Reserve to Applications.

macOS verifies the signed, notarized app when it opens. The release also
includes an optional
[`Reserve.dmg.sha256`](https://github.com/pocarles/reserve/releases/latest/download/Reserve.dmg.sha256)
for people who want to verify the download manually.

This manual step is required for the first Sparkle-enabled release. After that,
Reserve checks once a day by default and presents an **Install Update** button
when a newer signed release is available. It never installs silently.

Release assets are produced only by the protected GitHub release workflow. A
source build is ad-hoc signed and is intended only for the Mac that built it.

## Provider requirements

Open **Settings > Providers** and choose **Connect** beside a provider. Reserve
first checks for an existing sign-in, then guides you through only the steps
that are needed in one window.
If a helper needs installation or an update, Reserve explains the change and
waits for your approval. Browser sign-in opens on the provider's website in
your regular Chrome profile, with your existing sessions and saved passwords.
If Chrome is not installed, Reserve uses your default browser.
You can reopen that page or cancel the login from the connection window.

Claude and Cursor require explicit **Allow usage access** before Reserve reads
their protected sign-in. macOS may also ask you to approve access. The window
stays open until Reserve reads fresh usage, or explains why it could not.
Cursor, Windsurf, and Copilot start disabled. On first launch, the other providers
start enabled only when their helper is already installed. Saved choices are preserved.

- `codex`, signed into an OpenAI subscription;
- `claude`, signed into an Anthropic subscription;
- Grok Build 1.0.0 or newer, authenticated with `grok login`; and
- `cursor-agent`, authenticated with `cursor-agent login`, for an individual
  Cursor account. Teams and Enterprise Admin API keys are not supported;
- Devin Desktop or legacy Windsurf, signed in with its usage settings opened,
  for cached Windsurf plan usage;
- Copilot CLI, signed into GitHub. Setup opens GitHub’s installation instructions
  if the helper is missing.

Windsurf setup opens the installed desktop app. Sign in there, open its usage
settings, then choose **Check again** in Reserve. Reserve reads only the saved
plan metadata. It never reads Windsurf's protected sign-in or asks for Keychain
access. If the desktop app is missing, setup opens its official download page.

The same connection window handles installation, updates, sign-in, permission,
and the first usage check. Provider installation and updates never
run silently. Installer downloads are bounded, remain on the provider's exact
official HTTPS host, run with a minimal environment that excludes unrelated API
keys, and are removed from temporary storage afterward. Sign-in browser
handoffs remain restricted to the provider's expected HTTPS hosts. Temporary
setup and login output stays in memory.

Anthropic's subscription-usage endpoint is not a documented public API and may
change or rate-limit Reserve without notice. Cursor's authenticated individual
usage RPC is also undocumented and may change without notice. Grok Build 1.x
does not expose its billing method through ACP, so Reserve reads the
authenticated billing endpoint used by the CLI. OpenAI limits come from Codex
app-server JSON-RPC. Provider changes can temporarily break a refresh even when
the local app is healthy; the last valid snapshot remains visible and is marked
stale.

Claude can also share the limits in its documented status-line output. Enable
**Get updates from Claude Code** in its provider details. Reserve then reads a
quota-only local file and does not read Claude’s sign-in. Updates arrive after
Claude Code responds, so they pause while it is idle. The existing status line
is preserved; turning the option off restores it. No conversation text is saved.

Local history is available by default and can be turned off with **Include
activity from this Mac** in General. Only enabled providers are scanned, and
history work begins when Insights is requested. Normal quota checks skip
detailed Cursor history, reuse plan metadata, and check at most two providers
concurrently in a sweep.

See [provider support](docs/PROVIDER_SUPPORT.md) for the data contracts and
remaining provider verification limits.

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
swift run reserve-probe cursor
swift run reserve-probe windsurf
swift run reserve-probe local
```

The probe prints snapshots and errors, never credential material. The
Anthropic and Cursor probes honor the same explicit Keychain-consent setting as
the app.

## What Reserve shows

Every allowance uses the same projection model: reserve, on pace, deficit,
exhausted, stale, or unknown. Provider cards combine remaining capacity, reset
time, progress, pace marker, and a short projection. A currently exhausted
five-hour or daily limit takes priority over a longer allowance. Forecasts wait
until at least 10% of a known window has elapsed, and stop when observations
are stale. Grok’s Build and Chat contributions appear only in details as
percentages of its shared pool used.

Cursor shows its reported Cursor Models and Other Models percentages as whole
numbers. It also shows provider-reported tokens for today, the current billing
cycle, and the last 30 days. Reserve does not derive a percentage from token
totals. Hobby, Pro, Pro Plus, and Ultra default to $0, $20, $60, and $200 per
month; Cursor's reported plan price and renewal date take precedence when
available. On-demand spending is shown literally as disabled, unlimited, or a
dollar amount used against its configured cap.

Windsurf shows saved daily and weekly remaining allowances, their reset times,
plan name, renewal date, and extra usage balance when present. Its source is
labelled **Devin Desktop account cache**. Expired windows are omitted; expired
billing periods and caches with no current windows produce an error while
Reserve keeps the last valid snapshot visible. Multiple saved accounts are
rejected rather than guessing which account is active.

The desktop cache has no exact observation timestamp. Reserve conservatively
keeps the time it checked the cache separate from the unknown observation time.
It labels the amount as last known and never projects a forecast from it. These numbers can lag the Windsurf account page;
this version does not make an authenticated live usage request. Windsurf token
counts, transcript estimates, and subscription price guesses are not included.

The optional comparable-value view is an API-equivalent estimate, not a provider bill.
OpenAI and Anthropic use the observed input/cache/output mix when available;
Grok exposes an aggregate token count, so its comparison is approximate.
Subscription prices remain user-editable. Details distinguish reported, typical,
and manually entered prices. Empty detail rows are omitted.

Cursor's account insights come from provider-reported aggregate usage. Reserve
labels their dollar total **Provider-reported usage value** rather than estimated
API savings. It aggregates input, output, cache-read, and cache-write tokens and
model totals without reading prompts or transcripts. It requests bounded daily
history separately. If Cursor supplies totals without daily events, Reserve
keeps the totals and says **Daily history unavailable** instead of inventing a
chart.

OpenAI can report additional named allowance buckets, available reset credits,
and account token history. Reset credits appear only when available; Reserve
does not spend them. Insights requests account history only when needed and
shows the reported token totals without inventing a price or input/output split.
Older helpers can omit this history while continuing to report allowances.

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
logs are never cached. Cursor's normalized daily and model totals may be cached
with the same bounds as other aggregate usage data.

Local totals come from session logs under `~/.claude/projects`,
`~/.codex/sessions`, and `~/.grok/sessions`; only bounded daily aggregates are
retained. Reserve never scans Cursor transcripts or prompt text. It may read
`~/.claude/.credentials.json` and
`~/.grok/auth.json` when present. Claude Code can instead keep its sign-in in
Keychain; Reserve reads it only after the user chooses **Allow access**, through
the signed macOS `security` tool, and retains it in memory only. Reserve starts
that tool directly, captures bounded output through a private pipe, and never
prints or saves the credential. This addresses the repeated approval prompts caused by Claude Code restoring
its Keychain access list after browser sign-in; macOS can still require access
approval when its security settings change. A
current protected sign-in takes precedence over legacy credential files left
behind by Claude Code.

For Cursor, Reserve first runs the official
`cursor-agent status --format json` command with strict time and output limits
so Cursor can refresh its own credential. Only after **Allow access** does
Reserve read the `cursor-user` / `cursor-access-token` Keychain item. It never
reads the Cursor refresh token, writes Cursor Keychain items, or stores the
access token or raw DashboardService responses. Scheduled refreshes disallow
Keychain interaction, and turning access off invalidates an in-flight refresh.

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
                       /   |    |    \
                  Codex Claude Grok Cursor
                   RPC  HTTPS HTTPS HTTPS
```

`ReserveCore` owns provider, cache, scanner, and notification-domain behavior.
The `Reserve` executable owns AppKit surfaces and orchestration. The repository
also contains `reserve-probe`, `reserve-selftest`, and a standard SwiftPM test
target.

## Troubleshooting

**Connecting a provider.** Choose **Connect** on its card, or enable it in
Settings > Providers. Follow the steps in the connection window. No Terminal
commands or copied tokens are needed.

**Already signed in, but permission is needed.** Choose **Connect**, then
**Allow usage access**. Approve macOS access if prompted. Denied access stays a
permission problem and does not automatically send you through another login.

**Saved sign-in cannot be used.** Choose **Sign in again** to reconnect in your
browser. Reserve checks your usage after sign-in; macOS may still ask for access.

**The browser did not open.** Choose **Open browser again** in the connection
window. **Cancel** stops Reserve's login attempt. You can start again later.

**Cursor briefly loses access.** Reserve reloads its credential through the
existing Cursor Agent status check and retries once before requesting sign-in.
A provider rejecting account permissions does not automatically mean the
session expired.

**Disconnecting a provider.** In Settings > Providers, expand the provider and
choose **Disconnect from Reserve**. This stops checks, removes Reserve's cached
usage for that provider, and turns off its usage-access permission. It does not
sign you out of the provider's own app or uninstall its helper. The tracking
checkbox can pause checks without clearing cached usage.

**Data is stale or rate limited.** Reserve keeps the last valid snapshot and
retries after a bounded backoff. Check the provider's linked official status
page before reconnecting.

**A source-built app is blocked on another Mac.** Build it on that Mac or use
the signed and notarized DMG from GitHub Releases. Ad-hoc builds are not
portable.

**The optional checksum fails.** Delete both downloads and retrieve them again
from the same GitHub Release. Do not open the DMG.

## Contributing and release process

Focused contributions that improve the lightweight six-provider product are
welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md). Maintainer release operations
are documented in [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## Independence and trademarks

Reserve is an independent open-source project. It is not affiliated with,
endorsed by, sponsored by, or an official product of OpenAI, Anthropic, xAI,
Anysphere, Cognition, GitHub, or Microsoft.
Provider names and marks belong to their respective owners. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. Copyright © 2026 Pierre-Olivier Carles. See [LICENSE](LICENSE).
