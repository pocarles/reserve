# Reserve 1.1.3 candidate assessment

Date: 2026-09-05. Status: local candidate prepared; not cleared for publication.

## Candidate

- Source: codex/fix-claude-keychain-prompt, based on fd1f662 plus the saved
  authentication changes. These changes are uncommitted.
- Proposed version: 1.1.3. Latest public release checked through GitHub is 1.1.2.
- Local packaging test build: 31. The release workflow currently derives its
  production build from GITHUB_RUN_NUMBER; the last release run was 23. Before
  release, ensure the production build is higher than installed test build 30
  if this Mac is expected to receive it through Sparkle. Do not assume that
  the local test build number changes the workflow.
- Public draft: RELEASE_NOTES_1.1.3.md.

## Passed in this run

- `make check`: warnings-as-errors build, 50 Swift tests, 43 core self-tests,
  native dashboard checks, lifecycle checks, and connection flow checks.
- Connection fixtures cover initial connection, expired sessions, permission
  recovery, rejected access, fresh-usage verification, cancellation, disconnect,
  browser callback routing, and Cursor storage failures despite exit status 0.
- `RESERVE_VERSION=1.1.3 RESERVE_BUILD_NUMBER=31
  RESERVE_OUTPUT_DIR="$PWD/.build/release-candidate-1.1.3"
  Scripts/package_app.sh --mode dry-run`: passed. Universal 2 release
  compilation, bundle metadata, signature structure, launch smoke test, DMG
  production and checksum verification passed. This is ad-hoc signed, not a
  distributable Developer ID notarized release.
- `shasum -a 256 -c Reserve.dmg.sha256`: passed in the candidate directory.
- Evidence logs: .build/release-check-20260905.log and
  .build/package-candidate-1.1.3.log.

- A bounded read-only authentication review found no validated blocker in the
  inspected connection, retry, cancellation and cleanup paths. This is not the
  full security scan required by the release checklist.

## Live evidence and limits

- Installed 1.1.2 build 30 successfully fetched Cursor usage after the Mac
  restart on September 5. Earlier installed builds verified regular Chrome
  handoff and live OpenAI/Grok usage. See CONNECTION_FLOW_CHECKS.md.
- Claude is intentionally simulation-only because the user no longer has a
  Claude plan. This does not establish a real paid-account usage round trip.
- This run does not claim a clean-Mac first connection or a signed in-app
  upgrade for the 1.1.3 artifact. It does not replace the same-day manual
  product gate in RELEASE_CHECKLIST.md.

## Before publication

- Review and commit the candidate, merge through the release process and run
  CI on that exact commit. No commit, push, merge or tag was authorized here.
- Complete the documented security and manual product gates, explicitly
  resolving the Claude live-account coverage limit.
- Produce the protected signed/notarized rehearsal with a suitable build
  number; verify clean installation and the signed update from the previous
  public version. Keep all credentials in the protected release environment.
- Publish only after the final candidate and remaining gates are approved.
