# Reserve 1.4.0

Reserve now measures what your API accounts are spending, alongside the
subscription plans it already watches. An API account is a separate thing to
run out of, so it gets its own place rather than being mixed into the provider
cards.

- **Settings → API** is new. Paste a key for OpenAI, Anthropic, OpenRouter,
  xAI or TypeSafe and Reserve reads that account's spend from the provider's
  own billing endpoint. Each row is off until you save a key, and measurement
  stops the moment you remove one.
- **Get a key** opens that provider's own key page in your browser, and each
  field shows the prefix to expect, so setting one up does not mean hunting
  through a console.
- Keys are stored in the **macOS Keychain** on this Mac only — never on disk,
  never in preferences — and each key is sent only to the provider that issued
  it.
- Where a provider breaks its billing down, Reserve shows **what the spend went
  on**: models for Anthropic, billing line items for OpenAI. The card names one
  only when it is most of the bill; the full breakdown is in the tooltip and in
  Settings.
- OpenRouter reports **today, this week and this month**, plus the credit
  balance when the key is capped.
- TypeSafe publishes no spend endpoint, so Reserve lists the models your key can
  send and the documented input price. It does not call System One, which would
  consume your account in order to measure it.
- Refreshing Reserve now refreshes these measurements along with the
  subscription cards.

Your API spend appears in its own section on the dashboard, below the provider
cards. It does not replace them, and Reserve never sends a key anywhere except
the provider that issued it.

Provider connections, saved sign-ins, and settings are untouched. If you do not
save an API key, nothing about Reserve changes.
