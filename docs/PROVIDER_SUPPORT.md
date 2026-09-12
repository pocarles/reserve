# Provider support

Reserve checks remaining allowances without sending prompts. Provider data takes precedence over estimates. A missing reset time, billing amount, or plan name stays missing.

## Adding a provider

Start with a read operation that reports an account allowance and can run without a conversation. Check the provider's current documentation and the transport used by its own client. Session token totals and billing history alone do not establish how much allowance remains.

`ProviderDescriptor` contains the fixed provider names, helper definitions, account and status links, and capabilities. Add the provider identity and descriptor together, then implement its `UsageProvider` adapter and connection flow. Keep authentication specific to the provider. Shared contract tests should cover malformed values, stale data, cancellation, and the meaning of each displayed limit.

Prefer an existing signed-in app. Make helper installation explicit, retain the last usable snapshot after a failed refresh, and explain how to recover. Do not request broader billing permissions merely to show an allowance. Do not treat a helper's process exit as proof that its account is connected.

## Existing providers

### Claude

The optional Claude Code status-line connection accepts documented `rate_limits`
five-hour and seven-day windows. It stores percentages, reset times, and the
observation time only. The receiver preserves an existing status-line command
and forwards its original input and output within size and time limits. Turning
the option off restores the previous setting and respects later user edits.
This is a passive source: it updates after Claude Code responds and becomes
stale while Claude Code is idle. It does not fall back to reading credentials
when the passive option is selected. The documented feed is limited to supported
Pro/Max accounts. [Status-line documentation](https://code.claude.com/docs/en/statusline)

The direct connection remains available. Reserve retains explicit consent when
macOS temporarily needs interaction; only a user choice revokes that consent.

### Grok

Reserve caches the helper version until the executable changes. A billing 401
causes one credential reread and one retry only if Grok has already renewed the
same user's token. It does not start a speculative refresh command. Grok's
source warns that terminating refresh-token rotation can orphan the saved
session. A safe public renewal operation must be established before Reserve
can initiate silent renewal itself. [Official refresh implementation](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-login/src/manager/remedy.rs)

### OpenAI

The Codex app-server adapter reads named limit buckets and available reset
credits. Optional `account/usage/read` supplies account token activity in
Insights; an unsupported endpoint leaves quota checks working. Total tokens
are not assigned an invented input/output split or price. Quota-only polls do
not retain account activity without verified account identity. No reset credit
is redeemed and no conversation is started. [App-server documentation](https://developers.openai.com/codex/app-server)

### Cursor

Ordinary checks read allowance and spending limits. Plan metadata is cached for
an hour; requested account history is reused for fifteen minutes. Both are
isolated by credential and billing cycle. A usable, consented Keychain session
avoids a helper launch. Missing or rejected credentials may invoke one bounded
recovery path; a locked Keychain does not trigger an unrelated login. Detailed
history failures preserve quota and keep the history's original timestamp.

### Windsurf

Saved usage has no trustworthy observation timestamp. Reserve records when it
checked the file separately, labels the amount as last known, and suppresses
forecasts and quota-crossing alerts from unknown-age observations.

## Copilot

The native adapter reads GitHub's documented `account.getQuota` operation. GitHub describes remaining percentage, entitlement, use, and reset date; unlimited products are identified separately. Reserve shows finite allowances and omits unlimited products from percentage bars. It does not infer a monthly price, extra charge, or forecast from a quota reset date. [Quota documentation](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing)

Reserve starts the installed Copilot runtime briefly with `--headless --no-auto-update --stdio`. It sends `connect`, checks protocol version 3, reads `auth.getStatus`, then reads `account.getQuota`. A runtime without `connect` gets the official legacy `ping` fallback. Unsupported quota methods or protocol versions return an update action. Reserve creates no session and has no prompt or tool execution path in this adapter. [Official SDK client](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts), [generated RPC schema](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/rpc.ts), [protocol version](https://github.com/github/copilot-sdk/blob/main/nodejs/src/sdkProtocolVersion.ts)

The runtime owns its saved sign-in and token renewal. Reserve does not extract its tokens. Only ordinary process environment fields pass to the helper, so an inherited CI token cannot silently select another account. GitHub documents reuse of saved Copilot credentials and GitHub CLI fallback. [Authentication](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate)

Copilot installation opens GitHub's instructions. It never passes an HTML documentation page to the shell installer. The user-facing sign-in command is `copilot login --web-flow`. [Installation](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli), [login reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)

The transport caps individual messages at 64 KiB, bounds headers and queued messages, discards stderr, and stops on cancellation or a 15-second deadline. Provider error text is not copied into the interface. Tests exercise fragmented frames, invalid output, protocol fallback, signed-out accounts, unknown methods, timeout, and cancellation using a local fake runtime.

The documented interface was checked on September 12, 2026. GitHub's generated quota schema is marked experimental. Copilot's runtime was not available for authenticated testing in this implementation session. Protocol fixtures prove the requests Reserve sends and how responses are handled. They do not prove compatibility with an installed Copilot release, employer-managed accounts, or GitHub's current billing variants. Verify those with a consenting account before treating Copilot as release-verified.

### Billing research

GitHub's personal billing reports accept fine-grained user tokens with read-only Plan permission. Organization reports have separate endpoints and require organization permissions. A future spending view must establish which account pays before selecting a report. Billing history is not a substitute for the quota operation. Reserve does not request a billing token or call these endpoints in this implementation. [Billing API](https://docs.github.com/en/rest/billing/usage)

## Gemini

Gemini CLI documents `/stats model` as an interactive view containing token counts and quota information. This establishes that its own client can display quota; it does not document a standalone JSON quota command for another app. [Command reference](https://geminicli.com/docs/reference/commands/#stats)

Gemini remains a feasibility item. Do not add a provider card that cannot finish setup, scrape terminal decoration as an API, or submit a prompt to discover quota. The next requirement is a supported read-only interface, including its account scope and authentication renewal. Then check that the reported allowance is Gemini CLI or Code Assist usage, rather than assuming it also represents Gemini's consumer app.
