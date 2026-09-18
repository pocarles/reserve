# Reserve 1.4.1

A fix-up release for the Claude card, Settings and updates, plus more detail
for every provider when you open its card.

- **Claude shows every limit it has.** The weekly limit, the 5-hour window and
  each per-model limit (such as Fable or Sonnet) now get their own meter. A
  nearly spent model limit no longer takes over the card or the menu bar; the
  plan's weekly limit stays in front.
- **Pasting a key works.** Command-V, Command-C, Command-X, Command-A and
  Command-Z now work in the API key fields and every other text field in
  Settings.
- **Update windows come to the front.** Checking for updates no longer opens
  the update window behind Reserve's own windows.
- **A clearer API icon** in Settings.

Open a provider card with its chevron to see more of what the provider
reports:

- **Claude:** the signed-in account, your organization on Team and Enterprise
  plans, when your subscription started, and whether extra usage is off.
- **Codex:** the signed-in account, credit balance, a per-user spend cap, why
  usage is blocked when it is, lifetime tokens, your busiest day and streaks.
- **Grok:** prepaid balance and whether on-demand usage is on.
- **Cursor:** total included usage and a team's shared pool.
- **Copilot:** requests used out of your allowance, and which products are
  unlimited.
- **Every provider:** input, output and cache tokens over 30 days, this billing
  cycle's tokens and value, and any open incident, affected component or
  scheduled maintenance on the provider's status page.

The collapsed cards look the same as before. To name your Claude account,
Reserve reads the account email, organization and subscription dates from
Claude Code's own settings file; account emails and organization names are
shown but never saved to Reserve's cache.
