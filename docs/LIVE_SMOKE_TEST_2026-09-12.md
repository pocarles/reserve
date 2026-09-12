# Live provider smoke test — September 12, 2026

Tested the local `codex/reserve-everyday` adapters using existing provider sessions. The installed Reserve app was not replaced. No provider was installed, no browser login was initiated, and no access preference was changed. No commit or release was made.

| Provider | Result | Evidence |
| --- | --- | --- |
| OpenAI | Passed | Live allowance response included three windows, named Spark limits, and one available reset credit. Optional account activity returned 242 daily buckets. No credit was redeemed. |
| Cursor | Passed | Live allowance response included two windows, the reported plan price and billing renewal. The separately requested account history returned 30 daily entries without a details error. |
| Windsurf | Saved-data check passed | The desktop cache returned a current weekly window. Observation time remained unknown and distinct from the time of this check. This does not establish live account freshness. |
| Claude | Live test unavailable | The initial check requested access. The user subsequently confirmed they have no Anthropic subscription, so subscription validation cannot be completed on this account. Fixture tests passed; the passive bridge was not installed or enabled. |
| Grok | Passed after user renewed sign-in | Recheck at 19:24 UTC returned a live weekly pool with 22% used and Build/Chat contributions of 16% and 6%. The adapter adopted the renewed session without another login. This does not prove automatic token renewal. |
| Copilot | Helper missing | The CLI was not installed or discoverable. Live compatibility remains unverified. |

The probe gained an optional `--insights` switch to exercise the same on-demand history paths as the app. It compiled with warnings treated as errors. `git diff --check` passed. Detailed account-history responses were reduced to presence, source, and bucket counts for reporting; no credential values were printed or recorded.

These results validate the adapters on the accounts available on this Mac. They do not prove other subscription tiers, account switching during a live fetch, or long-running authentication stability. The prior fixture and native UI verification remains separate from these live results.
