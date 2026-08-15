# Security policy

## Supported versions

The latest published Reserve 1.x release receives security fixes. The `main`
branch is development code and may change without notice. Older prerelease and
source-only snapshots are not supported.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/pocarles/reserve/security/advisories/new).
Include the affected version and macOS version, a minimal reproduction, likely
impact, and suggested remediation if available.

Do not open a public issue, pull request, discussion, or social post containing
exploit instructions, credentials, private provider data, or an unpatched
vulnerability. Do not test against accounts or machines you do not own or have
explicit permission to assess.

The maintainer will acknowledge a usable report as soon as practical, validate
scope, coordinate a fix and release, and credit the reporter unless anonymity
is requested. A specific remediation or disclosure deadline cannot be promised
before the impact and complexity are understood.

## Security boundary

Reserve is a same-user desktop utility. It reads explicitly documented local
CLI state, starts fixed provider CLI commands, and connects to fixed provider
and GitHub HTTPS destinations. It does not run a server, ingest untrusted remote
documents, store credentials, extract browser cookies, or download/execute
updates.

Issues that require another local process already running as the same macOS
user may still be worth hardening, but reports should describe that prerequisite
so severity is calibrated accurately.
