# Provider connection verification

Verified locally on September 4, 2026, in
`/Users/pocarles/Documents/Projects/Reserve/.worktrees/fix-claude-keychain-prompt`,
branch `codex/fix-claude-keychain-prompt`, based on `fd1f662`.
Changes are uncommitted. A signed and notarized local build was installed on
September 4 after recovering the local signing setup.

## Behavior

- Connect checks the existing session before opening the provider's browser login.
- One native window handles setup, permission, login, and verification. Failed
  logins require an explicit retry. The browser can be reopened or login cancelled.
- Connected requires a completed usage check with usable data. A cached snapshot
  or successful login process alone is insufficient.
- Cursor reloads credentials and retries once on authentication rejection.
- Account access denial, macOS permission, expired login, and temporary usage
  failure remain distinct.
- Claude's background Keychain probe stays noninteractive. Explicit access can
  wait up to two minutes for macOS approval; background tool reads retain their
  three-second limit. Cancelling terminates a pending provider process.
- Disconnect stops checks, revokes Reserve's usage-access preference, and clears
  cached usage without signing out of the provider's own app. Late responses
  cannot restore the disconnected account.

## Passed checks

Run from the worktree above:

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
.build/debug/reserve-selftest
.build/debug/Reserve --self-test-connections
.build/debug/Reserve --self-test-ui
.build/debug/Reserve --self-test-lifecycle
swift build -c release -Xswiftc -warnings-as-errors
git diff --check
```

Results: 50 Swift tests, 43 core self-tests, native connection checks, dashboard
and settings checks, lifecycle checks, and both build configurations passed.
Connection tests use isolated preferences/cache, injected provider responses,
and local mock login processes. They do not authenticate real accounts.

Native checks cover existing sign-in, permission grant and denial, permission
granted while an older check is pending, browser reopening, failed login without
an automatic loop, cancellation, unavailable usage after login, empty usage,
disconnect during a pending response, and a process ignoring normal termination.
Rendered setup, browser, permission, connected, unavailable, and access-denied
windows were checked for clipped text; the setup, browser, and permission
screens were also inspected visually.

## Validation still required before release

### Signed local installation, September 4

- Packaged version 1.1.2, build 24 with `Scripts/package_app.sh --mode local`.
  The staged app is at `.build/local-install-20260904/Reserve.app`.
  Local package verification passed. The app and its Sparkle components were
  then signed with the same Developer ID identity as the installed build.
- Recovered the signing identity and notarization profile from the original
  certificate email. The recovered signing password is saved in Apple Passwords
  as `Reserve signing`. The previous locked signing keychain was preserved.
- Apple notarization accepted submission
  `d7c3795e-64a9-4d21-b8d4-50b84b46cd9c`. Stapler validation and Gatekeeper
  assessment passed; Gatekeeper reports `source=Notarized Developer ID`.
- Installed `/Applications/Reserve.app` version 1.1.2, build 24, ARM64 for this
  Mac. Verified `codesign --verify --deep --strict`, `xcrun stapler validate`,
  and `spctl --assess --type execute --verbose=2` on the installed app.
- Preserved the previous signed build in
  `.build/local-install-20260904/Reserve-rollback-1.1.2-23.zip` and verified the ZIP.
- The installed app fetched fresh OpenAI usage at `2026-09-04T21:01:44Z`.
  A separate live core probe also succeeded at `2026-09-04T21:03:38Z`.
- The live probe reports that Claude needs Reserve's explicit usage permission,
  Cursor's authentication has expired, and Grok has no available credentials.
  None of those three connections is counted as verified.
- The UI tool timed out attaching to the menu-bar-only app. A process sample
  showed its main thread idle in the normal AppKit event loop, not blocked in
  authentication. Requested that the user open the dashboard using its menu-bar
  icon so the native connection flow can be exercised.

### Installed follow-up, build 26

- Fixed reopening an already-running menu-bar app through Finder. Verified on
  installed build 25 that opening Reserve displays its dashboard. Build 26
  retains the fix and was also opened successfully through Finder.
- Keep Connect available during background checks. Limit activation-triggered
  retries to once per minute after the previous sweep completed, so an expired
  session does not cause repeated window activation to restart checking.
- A failed explicit macOS permission request now has a distinct
  `macOS did not allow access` state and a `Try access again` button.
- The build with these changes is installed as version 1.1.2, build 26.
  Notarization submission `ad0e0e9f-dd25-4b3e-8eef-ab17a902cd4d` was accepted.
  Signing, package verification, stapling, and Gatekeeper checks passed.
  Artifacts are in `.build/local-install-20260904-build26`.
- Reran warnings-as-errors debug build, native connection checks, UI checks,
  lifecycle checks, release packaging, and `git diff --check` successfully.
  Added meaningful checks for denied-permission recovery and the activation
  cooldown, including a backwards clock change.
- The installed app fetched fresh OpenAI usage at `2026-09-04T21:19:09Z`.
- Claude's explicit access attempt on build 25 was rejected immediately.
  A bounded diagnostic read of its Keychain item returned exit 51 and no
  credential. No credential value was printed. Claude is still not connected.
- Grok's installed-app flow opened browser sign-in and remained in the same
  native window while waiting. Verified Open browser again. The first Chrome
  profile was signed out of X; continued in the existing profile signed in as
  the user's X account. X is awaiting the user's account-access and terms
  approval. Do not count this as a completed Grok connection.
- Cursor's actual native connection remains unverified while Grok authorization
  is pending; the earlier live core check reported expired authentication.

### Installed Chrome handoff fix, build 27

- Reproduced the cause from running-process metadata: the same Chrome app had
  a normal instance and two automation instances using temporary data folders.
  Generic Launch Services URL opening could select the isolated instance.
- Added one shared sign-in opener that launches the installed Chrome executable
  with its normal user-data directory. Chrome forwards the URL to that existing
  instance. No browser cookies, passwords, or profile databases are read.
  If Chrome is absent, the default browser remains the fallback.
- Grok now uses its official device sign-in, which prints a complete browser URL
  with the code already filled in and does not launch another browser itself.
  Cursor uses its documented `NO_OPEN_BROWSER` option so Reserve owns its link.
- Verified warnings-as-errors compilation and
  `.build/debug/Reserve --self-test-connections`, including normal Chrome
  directory arguments, intact URL queries, trusted device-login hosts, recovery,
  cancellation, and connection verification. `git diff --check` passed.
- Packaged and installed signed/notarized version 1.1.2 build 27. Apple accepted
  submission `bcfbec76-2a5a-4911-af5d-0b3c994e03b6`; package, signature, stapling,
  and Gatekeeper verification passed. Build 26 is preserved in a rollback ZIP.
- On the installed app, clicked Grok Connect. Exactly one new tab appeared in
  the existing Chrome extension browser, profile `nimbus-suspensions.com`.
  The three existing Chrome process IDs remained unchanged. The page recognized
  the signed-in account, prefilled the device code, and reached consent after
  Continue. No manual URL transfer, password entry, or new Chrome instance.
- Grok's consent requests ongoing access, API use, and read/write Grok.com
  access, so final authorization is pending explicit user approval. The
  browser handoff is verified; a completed Grok usage refresh is not yet proven.
- Code remains local and uncommitted. No release was published.

### Claude saved-sign-in recovery, build 28

- User reproduced an immediate access failure in build 27. Claude's official
  `claude auth status --json` returned `loggedIn: false`, `authMethod: none`.
  Reserve was presenting an inaccessible leftover item as a permission-only
  problem, then repeating the same failed request.
- Changed failed access recovery to `Sign in again`. This explicitly bypasses
  the old-item permission redirect when starting the official login process.
  The new sign-in still requires a real usage check and any required consent.
  No Keychain item, password, or provider credential is deleted or modified by
  this recovery action itself.
- Warnings-as-errors build and native connection self-test passed. The regression
  test exercises denied access followed by a real child-process browser link and
  verified usage, proving it does not loop back into the same access request.
- Grok's live installed dashboard now shows current usage without Connect or
  stale-data status. Its account authorization was completed after build 27's
  browser handoff verification.
- Installed signed/notarized build 28. Apple accepted submission `eb5ab85d-5dcf-4697-9ef9-bf4e9fbd7c64`;
  package, signature, stapling, Gatekeeper, and installed version checks passed.
- Verified the actual installed UI: Allow usage access fails once, Sign in again
  opens a fresh Claude authorization tab in the normal Chrome profile. No
  repeated permission retry occurs in that recovery action.
- Claude's authorization page rejects the current browser account because it
  has no Pro or Max subscription. Claude's account menu identifies the active
  account as Free. Asked the user which account holds the paid subscription.
  Cancelled the pending helper rather than leaving an unusable login running.
- Found a separate callback gap: `claude auth login` prints a manual-code URL
  while independently opening its automatic callback URL. Build 28 consumed
  the printed URL. This is corrected in build 29 below.
- Claude is not connected. Real completion requires the correct subscription
  account, a working callback or explicit code return, and fresh usage.

### Claude automatic browser callback, build 29

- Claude's documented browser environment hook now points to a bundled helper
  that writes the actual automatic authorization URL to a private named pipe.
  Reserve consumes that URL and uses its normal Chrome opener. The manual-code
  fallback printed to stdout is ignored. Open browser again retains the actual
  callback URL. No Terminal interaction or copied code is needed for this path.
- The pipe is inside a unique 0700 temporary directory with mode 0600, bounded
  output, per-attempt generation checks, and cleanup on finish/cancel/failure.
  Authorization URLs travel in memory, not a regular file. The bundled helper
  is covered by the app signature. No browser credential store is read.
- The real installed Claude helper was exercised against this pipe with no
  authorization submitted: it delivered a localhost HTTP callback with its
  own dynamic port and /callback path, instead of the manual code page.
- Warnings-as-errors build, connection self-tests, release packaging, and
  git diff --check passed. Tests launch the bundled helper, verify exact URL
  delivery and cleanup, and cover the failed-permission-to-login recovery.
- Installed signed/notarized build 29; Apple accepted submission `f84cca10-6a60-400b-8484-c012de716ab2`.
  Signature, package, stapling, and Gatekeeper checks passed. Build 28 has a
  verified rollback archive in `.build/local-install-20260904-build29`.
- Native installed-app verification passed: failed access offers Sign in again;
  that action opens exactly one tab in the regular Chrome profile. The browser
  URL contains the automatic localhost /callback redirect. The manual-code URL
  is no longer opened. Correct subscription account and final Claude usage
  remain unverified; the current Chrome account has the Free plan.

### Remaining checks

- Claude is now intentionally validated with simulation: the user confirmed
  there is no current Claude subscription. Real Claude exchange and macOS consent
  are not claimed. Complete Cursor live reconnection separately.
  OpenAI, Grok, and the signed local installation are verified.
- Verify first connection on a clean Mac and behavior after sleep/wake and a
  signed app update with real provider sessions.
- Verify the locked-Keychain approval path on the signed app. Injected tests
  prove routing and deadlines, not macOS's actual approval interface.

No supported noninteractive Claude or Grok session-renewal mechanism was
confirmed in the reviewed source and documentation. Genuinely expired sessions
still require browser sign-in. Provider usage endpoints can also change
independently of Reserve.

### User-requested Claude simulation

- The user confirmed that Claude is no longer subscribed and requested simulation.
- Cancelled the real Claude login and confirmed no Claude login process remained.
- Expanded the native simulation to run Claude through the real private browser
  pipe, emit both a manual fallback and automatic callback, assert exactly one
  correct handoff, and return 20% used only after successful simulated login.
- Warnings-as-errors build, connection self-tests, and diff checks passed.
- Native evidence is clearly marked Simulation and saved in
  `.build/claude-simulation-20260904/`, alongside RESULT.md.
- Installed build 29 remains unchanged; no fabricated usage was put in the live
  app. Test defaults and cache were isolated and cleaned up. No commit or push.

### Cursor storage failure and window recovery, build 30

- Reproduced the real failure twice. Cursor's website confirms All set, but
  cursor-agent status reports isAuthenticated=false, hasAccessToken=false, and
  hasRefreshToken=false. Its official login implementation catches storage
  errors, prints Failed to store authentication tokens, and still exits zero.
- Reserve now retains bounded diagnostic output after opening the browser and
  recognizes this failure. A zero exit followed by a missing-session check also
  stops at the failure state. It does not restart browser sign-in automatically.
- The failure window explains the Mac storage problem, stops the spinner, and
  offers Close or Open Keychain Access. Opening Keychain Access closes the
  connection window. This action was verified on the installed build.
- Direct private reads of the Cursor access/refresh items returned exit 51
  (authentication failure), without returning credentials. The login keychain
  itself reports flags 7 (unlocked/read/write). Explicitly selecting login
  still returns 51; selecting the separate recovered signing keychain returns
  item-not-found 44. Keychain Access disables Lock Keychain login. This is not
  a browser callback problem. No keychain reset, deletion, or password change
  was attempted. No credential values were printed or retained.
- Native connection tests cover Cursor's explicit storage error with exit zero
  and the missing-session fallback. They verify no repeated browser link, no
  busy state after failure, and closing the failed connection window.
- Warnings-as-errors compilation, native connection self-tests, release package
  checks, and git diff --check passed. Installed version 1.1.2 build 30 passed
  signing, stapling and Gatekeeper checks. Apple accepted b03a2e6c-fe13-46ca-99e2-49d8c85fa72c.
- Live check: browser sign-in for the existing account completed; the installed
  Reserve window displayed the storage failure; Open Keychain Access opened the
  macOS utility and closed the connection panel. Cursor remains disconnected.
- Local Mac keychain recovery is still required. Do not claim Cursor working
  until its official status confirms a saved session and live usage is read.

### Post-restart live verification, September 5

- After the user restarted the Mac, the official cursor-agent status command
  returned isAuthenticated=true, hasAccessToken=true, hasRefreshToken=true,
  exit 0. Only these booleans were read into the report; no tokens were exposed.
- Installed Reserve 1.1.2 build 30 shows Cursor Pro+ connected, Other Models
  84% remaining and Cursor Models 99% remaining. No connection dialog remains.
- The installed app saved fresh Cursor usage at 2026-09-05T12:19:04Z, checked
  at 12:19:24Z. This supersedes the disconnected result above. No additional
  browser login or keychain repair was needed after the restart.
- Claude remains simulation-only as requested. No source changes, commit, or
  push were made during this post-restart verification.
