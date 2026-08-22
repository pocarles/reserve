# GitHub Actions runner policy

Reserve is the only repository in this group allowed to use an Apple-hosted
runner. The exception is limited to two jobs:

- `.github/workflows/ci.yml` builds and tests the AppKit application on pull
  requests.
- `.github/workflows/release.yml` builds, signs, and notarizes the macOS release.

The release publishing job stays on Linux. Do not add another Apple-hosted job
or any Windows-hosted job. The pull-request check named `reserve-macos-ci`
enforces this limit.
