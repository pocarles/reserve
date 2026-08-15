# Reserve release checklist

This is the maintainer runbook for a signed, notarized GitHub release. A
workflow success is necessary but does not replace the manual product gate.

## One-time Apple setup

The Apple Developer Program Account Holder must create the **Developer ID
Application** certificate. Export its certificate and private key as a
password-protected P12 for the release environment. Do not commit or paste the
P12, its password, or an API private key into logs or issues.

Create an App Store Connect API key authorized for notarization and retain its
P8, key ID, and issuer ID. Record the 10-character Developer Team ID.

## One-time GitHub setup

1. In **Settings > Environments**, create `release`.
2. Add Pierre-Olivier as a required reviewer. If he is the only release
   approver, leave **Prevent self-review** off so he can approve the tag run he
   triggered; enable it only after adding a second trusted release reviewer.
3. Restrict the environment to protected tags matching `v*` plus the default
   branch for manual rehearsals.
4. Add these environment secrets exactly:
   - `DEVELOPER_ID_CERT_P12` — base64-encoded P12;
   - `DEVELOPER_ID_CERT_PASSWORD`;
   - `APPLE_API_KEY_P8` — complete P8 contents;
   - `APPLE_API_KEY_ID`;
   - `APPLE_API_ISSUER_ID`;
   - `APPLE_TEAM_ID`.
5. Enable GitHub private vulnerability reporting.
6. Enable immutable releases if that repository option is available, so a
   published tag and its DMG/checksum assets cannot be silently replaced.
7. Protect `main`: require pull requests, at least one approving review,
   dismissal of stale approvals, resolution of conversations, and the `CI /
   verify` status check. Block force pushes and deletion. Apply the rule to
   administrators unless an emergency process is documented.
8. Protect tags matching `v*` so only maintainers can create them.
9. Set the repository description, homepage (`https://pocarles.com/reserve/`),
   and topics such as `macos`, `swift`, `menu-bar`, `codex`, `claude`, `grok`,
   and `open-source` after the landing page is live.

Repository workflows never expose Apple secrets to pull requests. The release
job imports credentials into an ephemeral keychain and removes key material in
an `always()` cleanup step.

## Candidate gate

- [ ] All v1 changes are merged through a reviewed pull request into protected
      `main`; the worktree is clean.
- [ ] `make check` passes on the final commit.
- [ ] CI passes, including the credential-free Universal 2 package dry run.
- [ ] A fresh security scan has no unresolved medium, high, or critical issue
      and no regression in the v1 availability-hardening paths.
- [ ] Shipped provider artwork is official and unmodified where its published
      terms permit this use, or has been replaced with plain names/neutral
      initials. Adapted third-party SVGs do not pass this gate by themselves.
- [ ] README, license, notices, security policy, migration notes, and release
      notes match the candidate.
- [ ] Bundle identity is `com.pocarles.reserve`, version is the intended stable
      X.Y.Z value, and the update check targets this repository only.

## Protected rehearsal

Run the **Release** workflow manually from `main` with the intended version and
a positive test build number. Approve the `release` environment. This creates a
signed and notarized workflow artifact but never a GitHub Release.

Download the rehearsal artifact and confirm:

```sh
shasum -a 256 -c Reserve.dmg.sha256
codesign --verify --strict --verbose=2 Reserve.dmg
xcrun stapler validate Reserve.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 Reserve.dmg
```

Mount the DMG and verify the app contains both architectures, has the expected
bundle/version metadata, and is signed by the expected Team ID. Install it by
dragging it to Applications, not by launching it from the mounted image.

## Same-day manual product gate

Use the rehearsal DMG on a Mac without an existing Reserve installation, then
repeat the migration checks on a Mac with valid legacy UsageBar data.

- [ ] Fresh install, first launch, quit, and relaunch succeed without a
      Gatekeeper override.
- [ ] Codex, Claude, and Grok each refresh successfully with a real authorized
      test account; disconnected/login handoff is checked without recording
      credentials or output.
- [ ] Valid legacy settings and aggregate caches migrate once. Invalid, unsafe,
      partial, and repeated migrations preserve legacy data and leave the new
      store usable.
- [ ] Sleep/wake recovery, launch at login, settings, notifications, manual
      update link, stale/backoff behavior, and provider status links work.
- [ ] The app remains responsive under oversized/malformed fixture cases,
      extreme counters, excessive local records, long provider identifiers,
      producer/consumer pressure, retained child-process pipes, and huge retry
      values.
- [ ] A 30-minute packaged-release idle sample stays below 0.2% CPU and 80 MB
      physical footprint. Record hardware, macOS version, commands, and samples
      in the release notes or private release evidence.

After the initial refresh settles, a reproducible sampling shape is:

```sh
reserve_pid=$(pgrep -x Reserve)
top -l 61 -s 30 -pid "$reserve_pid" -stats pid,cpu,mem,time > reserve-top.txt
footprint "$reserve_pid" > reserve-footprint.txt
```

Review the full interval rather than selecting a single favorable sample. Keep
these potentially machine-identifying diagnostics as private release evidence,
not in the public repository.

No 48-hour or seven-day soak is required for v1.

## Publish

1. Confirm the final commit is contained in `origin/main` and CI is green.
2. Create the protected stable tag, for example `v1.0.0`, on that exact commit.
3. Approve the `release` environment once the metadata shown by GitHub is
   correct. Tag runs publish only after signing, notarization, stapling,
   Gatekeeper, architecture, metadata, and checksum checks pass.
4. Download the public `Reserve.dmg` and `Reserve.dmg.sha256`; reproduce the
   checksum and fresh-install smoke test.
5. Verify the in-app update link and the landing page's latest-download URL.

If any gate fails, do not reuse or move the tag. Fix through `main`, increment
the version as appropriate, rehearse again, and create a new tag.
