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
provider state, starts fixed provider commands, and connects to fixed provider
and GitHub HTTPS destinations. It does not run a server, ingest untrusted remote
documents, store credentials, or extract browser cookies.

After a person explicitly chooses **Set up**, Reserve may download and execute
one of four fixed provider-owned installer scripts:

- `https://chatgpt.com/codex/install.sh`
- `https://claude.ai/install.sh`
- `https://x.ai/cli/install.sh`
- `https://cursor.com/install`

Reserve bounds the script to 1 MB, requires UTF-8 shell-script content, rejects
redirects away from the exact official host, writes it to a private temporary
directory, and runs it with a minimal environment that excludes unrelated API
keys. The temporary script is removed after execution. Provider installers can
download their own helper artifacts and write to their documented user-level
locations. Reserve cannot independently sign those provider-controlled
artifacts when the provider publishes no signing contract.

Provider setup and updates never run automatically. An **Update** action invokes
the already-installed helper's fixed, provider-documented update command.
Reserve's own app updates remain separately verified and installed through
Sparkle.

Issues that require another local process already running as the same macOS
user may still be worth hardening, but reports should describe that prerequisite
so severity is calibrated accurately.
