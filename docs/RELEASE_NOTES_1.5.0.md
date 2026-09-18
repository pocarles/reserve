# Reserve 1.5.0

Reserve now watches three more plans and two more API accounts, and checks the
programs and files it reads more strictly.

## New plans (beta)

- **Gemini:** Google AI Pro and Ultra limits, read from the Antigravity CLI
  (`agy` 1.1.11 or later, signed in). Gemini CLI no longer serves these plans.
  Reserve runs only `agy`'s own usage command and never touches your Google
  sign-in.
- **Z.ai GLM Coding Plan:** 5-hour and weekly limits. Connect it by pasting an
  API key from z.ai.
- **Kimi Code:** 5-hour and weekly limits. Connect it by pasting a Kimi Code
  API key.

These three are marked **Beta**: they have not yet been checked against real
accounts, and Z.ai and Kimi read usage from endpoints their makers have not
documented. If Reserve can't read one of them, it says so instead of showing a
wrong number. Please
[open an issue](https://github.com/pocarles/reserve/issues) and describe what
you saw, without your key, account name or email.

## New API accounts

- **DeepSeek:** your remaining balance, split into granted and topped-up
  credit, and whether it still allows calls.
- **Moonshot (Kimi API platform):** your remaining balance, split into vouchers
  and cash.

These keys can also call models, so create one just for Reserve. Like every
key, they stay in the macOS Keychain and are sent only to the provider that
issued them.

## Safer by default

- Before running a provider's command-line tool, Reserve checks every folder
  and link on the way to it. Anything another account on the Mac could have
  replaced is skipped.
- Session and credential files are opened once and read only through that
  open file, so a file swapped in the middle of a check is ignored instead of
  read.

## Connecting a provider

- When a sign-in can't start, Reserve now says why instead of repeating the
  same failed step. The button checks what is wrong rather than trying again.
- A signed-out Codex now offers sign-in. It used to show "temporarily
  unavailable", which nothing could fix.
- Declining the macOS permission prompt no longer starts a fresh Claude
  sign-in. Before any Claude sign-in, Reserve says plainly that it replaces
  the Claude Code sign-in on this Mac.
- If a provider's sign-in page doesn't open within 15 seconds, the window
  comes back instead of waiting out of sight.
- Install failures keep the installer's own message, and a Copilot CLI newer
  than Reserve supports now asks you to update Reserve.
- TypeSafe rows list each model with its release date.
