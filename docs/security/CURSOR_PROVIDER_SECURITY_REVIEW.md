# Cursor provider security review

Date: August 25, 2026

## Scope

This focused review covers the new individual Cursor provider: credential
consent, `cursor-agent` execution, DashboardService networking, normalized
cache data, logs, bundled artwork, and packaging. Teams, Enterprise Admin API
keys, browser sessions, cookies, prompts, transcripts, and release operations
are out of scope.

## Credential boundary

- Cursor starts disabled and `cursor.keychainReadAllowed` defaults to false.
- Reserve checks whether the expected item exists without returning its data.
- A token read happens only after **Allow access**. Scheduled refreshes set
  `LAContext.interactionNotAllowed` and cannot show a permission prompt.
- Reserve reads only account `cursor-user`, service `cursor-access-token`.
  There is no refresh-token query and no Keychain write path.
- Before the read, Reserve runs the located official `cursor-agent` with exactly
  `status --format json`. Output is limited to 64 KB, six seconds, and one JSON
  object. Dynamic-linker environment controls are removed.
- Disabling the provider or Keychain access advances the refresh generation, so
  an in-flight result cannot update the interface or cache.

## Network boundary

- Every authenticated RPC is a fixed method on
  `https://api2.cursor.sh/aiserver.v1.DashboardService/`.
- Requests require HTTPS and the exact `api2.cursor.sh` host. Redirects are
  limited by the shared provider session policy. Cookies and URL caching are
  disabled.
- Requests have a ten-second timeout and a 1 MB response limit. Usage events
  are capped at 250 per page, 20 pages, and 5,000 returned records. Duplicate
  events are removed before daily aggregation.
- Authentication and raw response data stay in process memory. Errors shown to
  the user contain fixed descriptions rather than provider response bodies.

## Cache and log boundary

- The snapshot cache contains normalized allowances, on-demand totals, plan
  metadata, and aggregate account-usage totals only.
- Tests reject access-token, authorization-header, raw-payload, path, prompt,
  and transcript material in persisted data. Existing size and file-mode
  limits remain in force.
- Cursor transcripts are never scanned. Detailed account usage falls back to
  plan limits without estimating from text.

## Packaging and artwork

- `cursor.svg` is the unmodified official 2D mark from Cursor's first-party
  brand archive.
- Package verification requires the Cursor artwork, and the trademark notice
  keeps Reserve's non-affiliation wording.
- No dependency, login service, cloud service, cookie access, or manual token
  entry was added.

## Verification record

Focused unit tests cover consent, silent scheduled access, HTTPS and host
constraints, authentication errors, rate limits, oversized payloads, malformed
values, both pools, billing reset, spending states, duplicate events, daily
aggregation, and pagination bounds.

Verification completed from the isolated implementation worktree:

- `make swift-test`: 34 tests passed.
- `make selftest`: 43 self-tests passed.
- `make ui-test`: passed with four provider cards, bundled artwork, keyboard,
  accessibility, notification, and status behavior.
- `make lifecycle-test`: passed across three appearance modes, four themes, all
  provider enablement transitions, and immediate Cursor access disablement.
- `make check`: passed, including warnings as errors and every preceding gate.
- `make package-dry`: passed for the Universal 2 app, signature verification,
  Cursor artwork inclusion, DMG, and checksum.
- The installed `cursor-agent` version `2026.08.11-e8db854` returned one valid
  JSON status object with `isAuthenticated` and `hasAccessToken` both true. No
  user or credential value was printed.
- The bundled Cursor SVG is byte-for-byte identical to the official 2D light
  cube (`c483c02f78eb2619778fdd959e72a9adfac4844854472cd2653d4cbfd60e4d71`).
- A live opt-in Keychain pass connected the individual account without exposing
  a credential. Reserve and Cursor's Spending dashboard agreed on Pro Plus,
  $60 per month, a September 24 reset, both included pools at 0%, and disabled
  on-demand spending.
- Cursor's Usage dashboard showed account events, but the authenticated
  DashboardService detail RPC was unavailable for this individual account.
  Reserve kept both plan allowances and displayed the documented limits-only
  fallback. It did not inspect transcripts or estimate token totals.
- Cursor's official Statuspage reported partially degraded service with one
  active incident during the pass, exercising the incident path.
- `cursor-agent logout` removed both Cursor tokens. Reserve then reported the
  fixed reauthentication message without using stale data. The official login
  restored the credential, and a new silent Reserve probe reconnected without
  a permission prompt or credential output.

Passing this comparison does not prove the undocumented Cursor RPC will remain
stable.
