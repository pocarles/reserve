# Reserve

Reserve is a native macOS menu-bar app that shows reported subscription
capacity for OpenAI Codex, Anthropic Claude, Grok, Cursor, Copilot, Gemini
(Google AI Pro and Ultra, through the Antigravity CLI), the Z.ai GLM Coding Plan
and Kimi Code.
Optional insights show provider-reported account activity or activity from this Mac.
Copilot support is experimental and still needs an authenticated release check.

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
first checks for an existing sign-in. If one works, the provider card simply
fills in. A window appears only when Reserve needs a decision from you or has
a problem to explain.
If a helper needs installation or an update, Reserve explains the change and
waits for your approval. Browser sign-in opens on the provider's website in
your regular Chrome profile, with your existing sessions and saved passwords.
If Chrome is not installed, Reserve uses your default browser.
Choose **Connect** again to reopen that page. If the browser could not open,
Reserve says so in a window where you can try again or cancel.

Claude and Cursor require explicit **Allow usage access** before Reserve reads
their protected sign-in. macOS may also ask you to approve access. That window
closes on its own once Reserve reads fresh usage, or explains why it could not.
Cursor, Copilot, Gemini, Z.ai and Kimi start disabled. On first launch, the other providers
start enabled only when their helper is already installed. Saved choices are preserved.

- `codex`, signed into an OpenAI subscription;
- `claude`, signed into an Anthropic subscription;
- Grok Build 1.0.0 or newer, signed into an X.AI subscription;
- `cursor-agent`, authenticated with `cursor-agent login`, for an individual
  Cursor account. Teams and Enterprise Admin API keys are not supported; and
- Copilot CLI, signed into GitHub. Setup opens GitHub’s installation instructions
  if the helper is missing;
- Antigravity CLI (`agy`) 1.1.11 or newer, signed into a Google account with a
  Google AI Pro or Ultra plan (see [Gemini](#gemini)), in beta;
- Z.ai GLM Coding Plan, connected with an API key, in beta; and
- Kimi Code, connected with an API key, in beta.

Gemini, Z.ai and Kimi Code are in beta: their usage formats have not yet been
checked against every kind of account, and Reserve marks them **Beta** in
Settings and in the connection window. If one shows an error or numbers that
look wrong, please [open a GitHub issue](https://github.com/pocarles/reserve/issues)
without your key, account name or email.

### Gemini

*Beta.* Since 2026-06-18, Gemini CLI no longer serves Google AI Pro, Ultra or free
individual accounts; those plans run through the Antigravity CLI (`agy`), with
5-hour and weekly limits per model group. Reserve shows each group's limits as
its own meter: the Gemini models group leads, and the Claude and GPT models
group sits beside it, like Claude's per-model limits.

Reserve reads them only by running agy's own usage command,
`agy -p /usage --output-format json`, which answers without starting a
conversation or spending quota. Reserve never reads agy's Google sign-in, never
calls Google's quota endpoints itself and never talks to agy's local server. It
first checks `agy --version` and refuses to ask an agy older than 1.1.11,
because older releases could send `/usage` to the model as a prompt. Each check
runs with no terminal, no input, a minimal environment (auto-update off, no
unrelated API keys) and a 30-second limit.

**Connect** can install agy with Google's official installer
(`antigravity.google/cli/install.sh`, into `~/.local/bin`). agy has no separate
sign-in or update command, so Reserve never starts it for either: open Terminal,
run `agy` and sign in with Google there (running it also updates it), then
choose **Check again**. Google publishes no Antigravity status page Reserve can
read, so the Gemini card shows no service status.

### Plans connected with an API key

*Beta.* Z.ai and Kimi Code have no helper and no sign-in. **Connect** asks for an API
key instead: paste it, or choose **Get a key** to open the provider's key page.
The key is saved only in the macOS Keychain and is sent only to that provider's
usage endpoint. **Remove** in Settings > Providers deletes the key, stops
checks, and clears the cached usage. Both show the same 5-hour and weekly
meters, reset times, pace, alerts and menu-bar source as the other providers.

- Z.ai: create an API key at z.ai (Manage API keys) on the account that holds
  the GLM Coding Plan. Reserve reads `api.z.ai/api/monitor/usage/quota/limit`.
  Only the international z.ai platform is supported; China-mainland
  `open.bigmodel.cn` keys are not.
- Kimi Code: create an API key in the Kimi Code console (kimi.com/code). This is
  the Kimi Code subscription, not the Moonshot API platform listed under
  Settings > API. Reserve reads `api.kimi.com/coding/v1/usages`.

Both usage endpoints are unofficial: they are what the providers' own tools
use, they are not documented, and they may change without notice. If a reply
is not understood, Reserve says so rather than showing a guessed 0%, and asks
you to report it on GitHub. Neither provider offers a read-only key, so the key you paste can also call models;
create a dedicated key just for Reserve. Z.ai publishes no status page, so its
card shows no service status; Kimi uses Moonshot AI's status page.

A saved sign-in expires on its own after a few hours. When Reserve finds one
that is expired or about to expire, it asks the provider's official helper to
renew its own session: `grok models` for Grok, and Claude Code's documented
refresh-token login for Claude. Reserve then reads the result from that
helper's own store. It never performs the token exchange and never writes a
provider's credentials. Browser sign-in is asked for only when nothing can be
renewed, or when the helper refuses the renewal.

The same connection window handles installation, updates, permission, and any
problem with sign-in or the first usage check. Provider installation and updates never
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

The dashboard shows every enabled provider in a compact overview. Select a tile
to show that provider's details below it: every allowance window and its reset,
activity from this Mac when that is turned on, provider-reported account
activity where it exists, the plan's cost and renewal, where the numbers came
from, and when they were last checked. Reserve restores the last selected
provider when the dashboard reopens, and the detail panel can pin that provider
to the menu bar.

Settings > General can register one of five fixed global shortcuts to open the
dashboard. It is off until you choose one. The adaptive refresh option checks
every 2 to 30 minutes based on how recently the dashboard was opened and uses
the longest interval in Low Power Mode or under high thermal pressure. Existing
fixed refresh choices remain available.

Cursor shows its reported Cursor Models and Other Models percentages as whole
numbers. It also shows provider-reported tokens for today, the current billing
cycle, and the last 30 days. Reserve does not derive a percentage from token
totals. Hobby, Pro, Pro Plus, and Ultra default to $0, $20, $60, and $200 per
month; Cursor's reported plan price and renewal date take precedence when
available. On-demand spending is shown literally as disabled, unlimited, or a
dollar amount used against its configured cap.

Settings > API measures consumption instead of subscription limits. Paste a key
there. It stays in the macOS Keychain on this Mac and is off until you save one:

- OpenAI, an organization admin key, read from the Costs API;
- Anthropic, an organization admin key, read from the Cost Report API;
- OpenRouter, the API key itself, read from that key's usage endpoint: today,
  this week, this month, and the credit balance when the key is capped;
- xAI, a management key, read from the prepaid balance API: spend against
  purchased credits when the transaction list explains the balance, and the
  remaining balance on its own when it does not;
- TypeSafe, the API key from the dashboard. TypeSafe publishes no spend
  endpoint, so Reserve lists the models that key can send and the documented
  input price. It does not call System One, which would consume the account;
- DeepSeek, an API key, read from the user balance endpoint: the remaining
  balance in the currency DeepSeek reports (USD first when the account holds
  both USD and CNY), split into granted and topped-up credit, and whether the
  balance still allows calls;
- Moonshot (Kimi API platform), an API key from platform.kimi.ai, read from the
  balance endpoint on api.moonshot.ai: the remaining USD balance, split into
  vouchers and cash. Keys from the China platform (api.moonshot.cn) are not
  supported.

OpenAI and Anthropic admin keys and xAI management keys can only read billing.
OpenRouter, TypeSafe, DeepSeek and Moonshot have no read-only key: the key you
paste can also call models, so create one just for Reserve.

Where a provider groups its billing, Reserve asks for the grouping and shows
what the spend went on: models for Anthropic, billing line items for OpenAI.
The card names a model only when one of them is most of the bill; the full
breakdown is in the tooltip and in Settings. A provider that will not accept
the grouping still reports its total.

Each row has **Get a key**, which opens that provider's own key page in your
browser; the field shows the prefix to expect. Refreshing Reserve refreshes
these measurements along with the subscription cards.

Those calls report spend or a remaining balance. They do not replace the subscription cards, and a
key is sent only to the provider that issued it.

The optional comparable-value view is an API-equivalent estimate, not a provider bill.
OpenAI and Anthropic use the observed input/cache/output mix when available;
Grok exposes an aggregate token count, so its comparison is approximate.
Subscription prices remain user-editable. Details distinguish reported, typical,
and manually entered prices. Empty detail rows are omitted.

Insights can compare 7, 30, or 90 days from the existing local history cache
without rescanning session files. Daily heatmaps distinguish a known quiet day
from a day Reserve has not observed and report how much of the selected period
is covered.

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

Z.ai and Kimi plan keys are kept as generic-password items under the
`com.pocarles.reserve.plan-keys` Keychain service, separate from the API keys
above. They are never written to preferences, the snapshot cache, or logs.

Local totals come from session logs under `~/.claude/projects`,
`~/.codex/sessions`, and `~/.grok/sessions`; only bounded daily aggregates are
retained. Reserve never scans Cursor transcripts or prompt text. It may read
`~/.claude/.credentials.json` and
`~/.grok/auth.json` when present (`GROK_AUTH_PATH` and `GROK_HOME` are
honoured, in that order). To name the signed-in Claude account in a card's
expanded details, Reserve also reads the account email, organization and
subscription dates from Claude Code's `~/.claude.json` (or
`$CLAUDE_CONFIG_DIR/.claude.json`); nothing else in that file is used. Account
emails and organization names are shown but never written to Reserve's cache.
Turn on **Hide personal info** in the menu or Settings > General to mask them on
screen. Share cards exclude those details regardless of that setting, along
with paths, raw errors, and provider-controlled free-form labels. Claude Code
can instead keep its sign-in in Keychain; Reserve reads it only after the user
chooses **Allow access**, through
the signed macOS `security` tool, and retains it in memory only. Reserve starts
that tool directly, captures bounded output through a private pipe, and never
prints or saves the credential. This addresses the repeated approval prompts caused by Claude Code restoring
its Keychain access list after browser sign-in; macOS can still require access
approval when its security settings change. A
current protected sign-in takes precedence over legacy credential files left
behind by Claude Code.

Renewal is always performed by the provider's own helper, started without a
shell, with no browser handoff, with no inherited input, and with its output
discarded. Because Reserve starts it on its own initiative, the helper receives
an allowlisted environment — the user's home, shell, locale, temporary
directory, search path, and the provider's own configuration variables — so
unrelated API keys in Reserve's environment never reach it. For Grok that is the public `grok models` command; for Claude it is
Claude Code's documented refresh-token login, which receives the refresh token
and scopes in its environment and stores the rotated credential in its own
store. Reserve reads the renewed session back from that store, holds it in
memory only, and never writes, prints, or caches a token.

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
Settings > Providers. Reserve opens the sign-in page, or a window with the next
step. No Terminal commands or copied tokens are needed.

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
