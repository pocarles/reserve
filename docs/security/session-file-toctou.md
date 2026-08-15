# Post-v1 issue: bind session-file validation to the opened descriptor

## Summary

Local usage scanning checks candidate session-file metadata before opening the
path. A same-user local process could replace the path with a symlink, FIFO, or
different file between validation and open.

## Security context

This requires a malicious or compromised process already running with the same
macOS user's ability to modify the provider session tree during Reserve's scan.
The scanner does not read paths supplied by a remote service, and its output is
bounded aggregate usage rather than raw session content.

## Desired outcome

- Open with descriptor-level no-follow/nonblocking protections appropriate to
  regular files on macOS.
- Use `fstat` after open and require a regular file, expected ownership, link
  constraints, and size/time budgets on that exact descriptor.
- Read from the verified descriptor rather than reopening the pathname.
- Treat replacement, FIFO, device, socket, and symlink cases as skipped input,
  never as fatal scanner failure.
- Add deterministic race and special-file tests that cannot block the test
  suite.

Do not broaden scanned directories or persist raw file content while fixing
this issue.
