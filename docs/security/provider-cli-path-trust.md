# Post-v1 issue: strengthen provider CLI path trust

## Summary

Reserve searches a bounded set of expected locations for the Codex, Claude,
and Grok executables. Current checks reject an obviously world-writable leaf,
but do not validate the complete ownership, group-write, symlink, and ancestor
chain or establish code identity before execution.

## Security context

This is a constrained local hardening issue, not a remote execution path. An
attacker must already be able to create or replace a candidate executable or
its path as the same macOS user (or through another locally privileged write).
Reserve does not accept executable paths from network responses or documents.

## Desired outcome

- Resolve symlinks and validate every ancestor through the trusted root.
- Reject unexpected owner, group/world-writable directory, device, or file
  type conditions without launching anything.
- Prefer exact paths returned by the user's interactive shell only when the
  same validation succeeds.
- Evaluate whether provider-published signing identity can be required without
  breaking official install methods; fail clearly rather than guessing.
- Add filesystem fixtures covering safe installs, Homebrew-style symlinks,
  hostile ancestors, races, and useful error messages.

Preserve compatibility with official helper installs. Provider setup must stay
user-approved, user-level, restricted to the fixed official installer catalog,
and separate from Reserve's own Sparkle updater. Do not add a privileged
helper, accept an installer URL from remote data, or silently install or update
provider software.
