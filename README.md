# Usage Bar

Usage Bar is a deliberately small macOS menu-bar application that shows the
subscription quota windows for OpenAI Codex, Anthropic Claude, and Grok.

The project is currently private and pre-release. Do not publish the repository,
create a public remote, or distribute builds without an explicit release decision.

## Product boundary

Usage Bar does one job: periodically fetch current subscription utilization and
reset times from provider-owned local CLI authentication. It does not include:

- browser automation, hidden WebViews, or cookie extraction;
- historical charts, local token-history scanning, or a database;
- widgets, notifications, plugins, multi-account switching, or iCloud sync;
- API spend reporting or status-page polling.

The app has no third-party package dependencies. Provider subprocesses exist only
for the duration of a bounded refresh.

## Requirements

- macOS 14 or newer
- Swift 6 (the current Apple Command Line Tools are sufficient to build)
- `codex` logged into the OpenAI subscription
- `claude` logged into the Anthropic subscription
- Grok Build 1.0.0 or newer, authenticated using `grok login`

Anthropic's subscription usage endpoint is not a documented public API and may
rate limit callers. Usage Bar persists a backoff of at least 15 minutes after a
429 and retains the last successful snapshot.

## Build and run

```sh
make check
make run
```

`make run` creates an ad-hoc signed `UsageBar.app` in the repository and opens it.
The generated app is ignored by Git and includes the project license and
third-party notices in its Resources directory.

To test a provider without the menu UI:

```sh
swift run usagebar-probe openai
swift run usagebar-probe anthropic
swift run usagebar-probe grok
```

The probe prints snapshots and errors only. It never prints credential material.
The Anthropic probe honors the same explicit Keychain-consent setting as the app.

`make check` also runs a native AppKit UI self-test. It constructs the real status
dashboard and settings window, then verifies all provider cards, summary indicators,
actions, checkboxes, and the refresh picker without changing any setting.

The popover derives its overview from the current provider snapshots: live provider
count, tracked limit count, nearest reset, and highest utilization. Each provider
card shows used and remaining quota, rolling-window duration, reset countdown,
absolute reset time, plan, source, freshness, and saved-data errors. Anthropic extra
usage and Grok included-credit totals appear only when the provider returns both a
used amount and a limit.

## Privacy and storage

The cache lives at:

```text
~/Library/Application Support/UsageBar/snapshots.json
```

It is capped at 100 KB and contains only usage percentages, reset dates, provider
and plan labels, fetch time, and source name. OAuth tokens, account identifiers,
cookies, authorization headers, raw provider responses, and subprocess logs are
never cached.

Claude Code may store its OAuth credential in macOS Keychain rather than
`~/.claude/.credentials.json`. Reading that foreign Keychain item is disabled by
default and requires explicit consent in Usage Bar settings. Consented reads use
Apple's `/usr/bin/security` helper with direct arguments and a five-second hard
timeout; credential JSON remains in memory only and is never logged or cached.

## Resource contract

- scheduled refresh interval: 10 minutes minimum;
- scheduled refreshes are skipped in Low Power Mode;
- no provider subprocess survives success, failure, or timeout;
- cached data remains visible when a provider is offline or rate limited;
- target idle CPU: below 0.2% over a 30-minute release-build sample;
- target idle physical footprint: below 40 MB as measured by `footprint`;
- cache size: below 100 KB.

CPU and memory targets are release gates and must be measured on a packaged build
before public distribution.

## Architecture

```text
AppKit NSStatusItem + NSPopover
             |
     AppKit dashboard popover
             |
          UsageStore
          /      \
SnapshotCache  UsageProvider
                /    |    \
             OpenAI Claude Grok
               RPC  HTTPS ACP/API
```

OpenAI uses the documented Codex app-server `account/rateLimits/read` method.
Anthropic uses the Claude OAuth usage endpoint with conservative backoff. Grok
first uses the official Grok Build `x.ai/billing` ACP extension. Grok Build
1.0.3 omits that method from its released ACP surface, so Usage Bar falls back
to the same authenticated `cli-chat-proxy.grok.com/v1/billing?format=credits`
request implemented by Grok Build itself. This reads CLI-owned OAuth state only;
it does not read browser cookies.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
