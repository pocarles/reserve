# Reserve

Reserve is a deliberately small macOS menu-bar application that shows the
subscription quota windows for OpenAI Codex, Anthropic Claude, and Grok.

The project is currently private and pre-release. Do not publish the repository,
create a public remote, or distribute builds without an explicit release decision.

## Product boundary

Reserve does one job: combine current subscription limits with a compact
view of today's and the rolling last 30 days of locally observed token usage. It does not include:

- browser automation, hidden WebViews, or cookie extraction;
- transcript storage or a raw usage-history database;
- widgets, plugins, multi-account switching, or iCloud sync;
- cloud analytics or third-party status aggregators.

The app has no third-party package dependencies. Provider subprocesses exist only
for the duration of a bounded limits refresh. The token scanner reads local CLI
session files directly and keeps only daily aggregates.

## Requirements

- macOS 14 or newer
- Swift 6 (the current Apple Command Line Tools are sufficient to build)
- `codex` logged into the OpenAI subscription
- `claude` logged into the Anthropic subscription
- Grok Build 1.0.0 or newer, authenticated using `grok login`

On first launch, Reserve immediately opens its dashboard, enables quiet launch
at login, detects the three installed CLIs, reuses their existing sign-ins, and
starts collecting the available local usage totals. There is no account wizard
and no separate Reserve account. If a provider is signed out, one Connect click
runs that provider's official CLI login (`codex login`, `claude auth login
--claudeai`, or `grok login --oauth`) and hands the sign-in to the default browser.
Temporary login output stays in memory, URLs are restricted to that provider's
HTTPS hosts, and neither is logged or cached.

The practical zero-action path assumes the provider CLIs above are already
installed and signed in. Reserve deliberately does not install or update those
tools itself; if one is missing, the dashboard reports it explicitly.

Anthropic's subscription usage endpoint is not a documented public API and may
rate limit callers. Reserve persists a backoff of at least 15 minutes after a
429 and retains the last successful snapshot.

## Build and run

```sh
make check
make run
```

`make run` creates an ad-hoc signed `Reserve.app` in the repository and opens it.
The generated app is ignored by Git and includes the project license and
third-party notices in its Resources directory.

To test a provider without the menu UI:

```sh
swift run usagebar-probe openai
swift run usagebar-probe anthropic
swift run usagebar-probe grok
swift run usagebar-probe local
```

The probe prints snapshots and errors only. It never prints credential material.
The Anthropic probe honors the same explicit Keychain-consent setting as the app.

`make check` also runs a native AppKit UI self-test. It constructs the real status
dashboard and settings window, then verifies the shared pace-state model, provider
cards, automatic and pinned menu-bar modes, theme tokens, actions, checkboxes, and
refresh decisions without retaining any test setting.

The popover fits its complete dashboard without scrolling. Clicking elsewhere
closes it, while clicks in Reserve Settings leave it open.

Both surfaces share one design system in `Sources/UsageBar/ReserveDesign.swift`:
a single type scale, restrained spacing and radii, plus semantic tokens for the
window, elevated surfaces, cards, borders, progress tracks, hover and selection.
The Matrix, Ember, Ocean, and Graphite themes provide visibly different adaptive
light/dark palettes for those structural tokens. Quota meaning remains separate:
green is reserve, blue is on pace, and orange is deficit or exhausted. Red is
reserved for provider-service incidents, never normal subscription pressure.

The dashboard leads with one factual conclusion. Every allowance is classified by
the same shared projection model as `reserve`, `on pace`, `deficit`, `exhausted`,
`stale`, or `unknown`; a two-percentage-point tolerance around the pace marker
prevents boundary flicker. Provider cards use one anatomy: identity, remaining
capacity, reset, progress and pace marker, then a short projection. Reserve and
deficit magnitudes are explicit, stale data keeps its last value but says the
forecast may be outdated, and an expired reset becomes unknown until refreshed.
Five-hour sessions remain secondary quotas with their own usage and reset.
Expanded detail keeps token totals, estimated API value, source provenance, and
the plan cost. Subscription costs remain editable because plan prices vary.
An optional billing day controls renewal alerts only; it never gates usage or savings.
Days 29–31 use the month's final day when needed.

Grok reports one shared weekly allowance. When the billing response includes its
product split, Reserve lists the Grok Build and Grok Chat shares below the main
bar with the shared pool's expiry. These are components of the weekly allowance,
not extra independent quotas.

Savings uses an internal API-equivalent estimate, not a provider bill. OpenAI and
Anthropic calculations use the observed input, cache, cache-write, and output mix
when available. Grok's local records expose an aggregate token count, so its
comparison remains approximate.

Each provider card also shows the current service health reported by that
provider's official status page. OpenAI and Claude use their official Statuspage
JSON summaries; xAI uses its official RSS feed. The health label opens the source.

Notifications are enabled by default, subject to macOS permission. The default
stream is forecast-driven: Reserve notifies when an allowance enters deficit,
when one is exhausted, when capacity returns, when a provider's numbers go stale,
and when a provider reports a service incident. Each reports a transition, so a
condition that persists does not notify again.
Fixed usage thresholds (50%, 90%), plan-renewal notices, five-hour reset notices,
and sound are available under Advanced and are off by default.

Settings is a native toolbar window with General, Providers, Notifications,
Appearance, Insights, and Privacy panes. Each pane sizes the window to its own
content, and About is the standard macOS About panel.

Appearance separates palette from meaning. System, Light, or Dark chooses the
effective appearance. Matrix, Ember, Ocean, or Graphite then supplies the full
adaptive structural palette, including window, elevated and card surfaces,
borders, progress tracks, accent, hover, selected, and chart colors. Every pace
state also carries an icon and text, so color is never the only signal.

The menu bar has one model. A pinned OpenAI, Anthropic, or Grok provider uses its
monochrome logo and that provider's percentage/reset details. Automatic mode uses
Reserve's monochrome gauge and selects the most relevant enabled provider: an
exhausted or deficit plan first, otherwise the least comfortable on-pace/reserve
plan. With both detail switches off it becomes a true icon-only item. General owns
these controls; Appearance shows only appearance, theme, and its live palette
preview. Clicking a provider card pins it immediately without opening Settings.

The compact About page shows the installed version, links to the planned public
GitHub repository and [@pocarles on X](https://x.com/pocarles), and opens the MIT
license bundled inside the app. Its manual update check reads only the latest
GitHub Release; until the repository is published, it reports that no public
release is available rather than treating that state as an error.

## Privacy and storage

The caches live at:

```text
~/Library/Application Support/UsageBar/snapshots.json
~/Library/Application Support/UsageBar/local-usage-index.json
```

The snapshot cache is capped at 100 KB. The local index is capped at 12 MB and
contains only daily token/cost aggregates plus hashed file keys and byte offsets
for incremental scans. OAuth tokens, account identifiers, local paths, prompts,
responses, cookies, authorization headers, raw provider payloads, and subprocess
logs are never cached.

Claude Code may store its OAuth credential in macOS Keychain rather than
`~/.claude/.credentials.json`. Reserve enables read-only reuse by default so an
existing Claude Code sign-in works without duplicate setup; it can be disabled at
any time in Settings. Reads use Apple's `/usr/bin/security` helper with direct
arguments and a five-second hard timeout; credential JSON remains in memory only
and is never logged or cached.

## Resource contract

- provider-limit refresh interval: configurable to 1, 5, 10, 15, or 30 minutes;
- official service-health refresh interval: 10 minutes minimum;
- local token-history scans: every 30 minutes, or immediately on manual refresh;
- scheduled refreshes are skipped in Low Power Mode;
- activation and wake refresh only when cached provider data is due;
- one shared minute-level UI clock updates visible reset countdowns; there are no
  per-card or one-second timers;
- no provider subprocess survives success, failure, or timeout;
- cached data remains visible when a provider is offline or rate limited;
- local usage scans run off the main thread and are incremental after first use;
- target idle CPU: below 0.2% over a 30-minute release-build sample;
- target idle physical footprint: below 80 MB as measured by `footprint`;
- snapshot cache: below 100 KB; local aggregate index: below 12 MB.

CPU and memory targets are release gates and must be measured on a packaged build
before public distribution.

## Architecture

```text
AppKit NSStatusItem + NSPopover
             |
     AppKit dashboard popover
             |
             UsageStore
          /       |       \
SnapshotCache Scanner  UsageProvider
                local    /    |    \
                logs  OpenAI Claude Grok
                       RPC  HTTPS HTTPS
```

OpenAI uses the documented Codex app-server `account/rateLimits/read` method.
Anthropic uses the Claude OAuth usage endpoint with conservative backoff. Grok
uses the authenticated `cli-chat-proxy.grok.com/v1/billing?format=credits`
request implemented by Grok Build itself. Grok Build 1.x does not expose its
billing method through ACP, so Reserve avoids launching the agent subprocess only
to receive a method-not-found response. This reads CLI-owned OAuth state only; it
does not read browser cookies.

## License

MIT. Copyright © 2026 Pierre-Olivier Carles. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
