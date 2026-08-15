# Contributing to Reserve

Reserve welcomes focused fixes and improvements that preserve its purpose: a
small, local-first macOS capacity monitor for Codex, Claude, and Grok.

## Before opening a pull request

- Search existing issues and discussions.
- Use an issue for significant behavior or interface changes before building.
- Keep new providers, cloud accounts, telemetry, automatic update execution,
  browser-cookie extraction, plugins, and broad platform expansion out of
  scope unless the maintainer has explicitly accepted a design change.
- Do not include credentials, provider payloads, transcripts, local paths, or
  other private data in issues, fixtures, screenshots, logs, or commits.
- Report security vulnerabilities privately as described in
  [SECURITY.md](SECURITY.md), not through a public issue.

## Development

Reserve requires macOS 14+, Swift 6, and AppKit. Run the complete local gate:

```sh
make check
```

That command builds with warnings treated as errors, runs standard SwiftPM
tests, the domain self-test, the native AppKit UI test, and the lifecycle test.
Use `make package` to inspect an ad-hoc local app. With full Xcode selected,
`make package-dry` exercises the Universal 2 DMG/checksum path without Apple
credentials.

Tests must be deterministic and must not use real provider accounts, network
responses, Keychain items, notification permissions, or persisted user
preferences. Add bounded adversarial cases when touching parsing, process I/O,
networking, file scanning, caches, or arithmetic.

## Pull requests

- Make one coherent change and explain the user-visible effect.
- Update tests and documentation with behavior.
- Preserve accessibility, reduced-motion behavior, and light/dark appearances
  for UI changes.
- Avoid new dependencies unless the maintenance and privacy cost is justified.
- Do not edit release versions in the tracked plist; the protected release
  workflow stages version/build metadata.
- Confirm that `make check` passes and describe any manual verification.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository and that you have the right to submit it.
