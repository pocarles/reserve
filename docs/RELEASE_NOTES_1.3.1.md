# Reserve 1.3.1

This release corrects regressions introduced in Reserve 1.3.0.

- Restores activity history for existing users unless they explicitly turned
  it off. History still runs only when Insights is open.
- Shows today and 30-day OpenAI activity instead of replacing it with a
  lifetime token total.
- States usage coverage and known monthly costs separately, so partial data no
  longer looks like an account-wide total.
- Hides unused or duplicate OpenAI model allowance buckets and promotes a
  nearly exhausted short window when it is the limit most likely to stop work.
- Replaces the dashboard's stacked summaries with one provider-specific
  conclusion.
- Adds visible **Connect** and **Reconnect** controls to provider rows in
  Settings.

OpenAI, Grok, Cursor, and Windsurf were checked with the existing provider state
on the release Mac. Claude remains disconnected on that Mac, and Copilot is not
installed.
