# Efficiency and recovery

Reserve schedules each provider separately. A failed provider backs off without causing successful providers to run again early. Explicit refreshes bypass the local delay but still honor the provider's Retry-After deadline. Subscription reads and API-consumption reads each have a concurrency limit of two. Service-status requests and local history run separately, so they cannot keep a completed allowance refresh spinning.

Background Keychain reads are silent and run on a serial utility queue. Only an item-not-found response means a key is missing. Locked or unavailable Keychain responses remain temporary failures and are retried automatically. UI save and remove operations await the background queue. A failed deletion keeps the saved-key state. Request generations prevent canceled or superseded work from publishing old results or enabling a provider again.

Low Power Mode and an unavailable network pause scheduled work. Returning to a usable state starts the providers that are due. An explicit refresh remains available. Existing sign-in consent requirements still apply.

Local history watches only enabled providers' session roots. File events mark changed paths; ordinary scans visit those paths and reuse small decoded indexes. Published indexes larger than 4 MiB are released after each operation to reduce idle memory. Dropped events, root replacement, renames, and ambiguous changes trigger a full walk. A periodic full walk remains as a fallback. Disabling history stops the watches and releases the resident index.

The index is reloaded when its validated file identity changes. Deletion or corruption triggers rediscovery. A scan that reaches its time or byte budget saves bounded progress separately, keeps the last published totals, and revalidates files before publishing a resumed result. Partial work never marks the old totals as freshly measured. The 64 MiB read budget is shared across providers. A pass that saves useful progress resumes automatically after a five-second pause at utility priority; an unchanged checkpoint stops retries. Continuations pause while offline or in Low Power Mode and resume when conditions recover. Disabling history cancels the pending work.

The dashboard and Settings apply ordinary reading changes to existing controls. Details and charts update with their values; privacy changes update expanded content. See [UI update checks](UI_UPDATE_CHECKS.md) for the lifecycle and performance gates.

## Fixture measurement

A paired debug-build measurement on September 22, 2026 used 1,120 generated log files: 1,000 Codex files and 120 Claude files with 100 messages each. Both builds produced identical expected token totals. The previous checkout was 708ce2787ece694cdc6cd267efd4757c68fd2a13.

| Operation | Before | After |
| --- | ---: | ---: |
| Initial scan | 398.67 ms | 418.04 ms |
| Unchanged scan, median of seven | 72.73 ms | 9.15 ms |
| Cached history, median of seven | 36.51 ms | 3.34 ms |
| Peak physical footprint of fixture process | 58.9 MB | 39.5 MB |

The final measurement includes the additional file-identity checks for same-length replacements. Unchanged scans were about eight times faster and cached-history reads about eleven times faster; the initial scan took about five percent longer. The generated index grew from 2.51 MB to 2.58 MB to store the stronger file identity. These figures describe the synthetic scanner workload on this Mac, not the installed app or a production provider response.

The regression suite checks skipped decoding and tree traversal directly, along with changed-file parsing, event loss, rotation, truncation, cache replacement, cancellation, and resumed scans. The full `make check` gate also covers provider recovery and native UI behavior. No test requires real provider accounts, credentials, or session logs.

## Verification

The final local check on September 22, 2026 passed all 287 Swift tests, 43 core self-tests, and the native UI, lifecycle, connection, stress, and recovery checks. Debug and native release builds passed with warnings treated as errors. The light and dark dashboard fixture renders were also inspected.

The stress run completed 30 popover and Settings open/close cycles with 9.3 MiB of physical-footprint growth against a 40 MiB budget. Eight cached-reading updates caused zero full dashboard replacements and zero region replacements; the slowest completed update took 0.03 seconds. This bounds repeated-cycle growth in the fixture; it does not establish a reduction in the installed app's idle memory.

Provider recovery checks use injected failures and credentials. Universal packaging and installed-app validation remain separate release checks.
