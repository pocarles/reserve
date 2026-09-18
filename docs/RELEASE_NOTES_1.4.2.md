# Reserve 1.4.2

API accounts now open like provider cards. Click the chevron on a row in the
API consumption section to see everything that key already reports. Reserve
makes no extra requests to show it.

- **OpenAI and Anthropic admin keys:** today's spend, the last 7 days, your
  busiest day, the daily average, and every model or line item this month.
- **OpenRouter:** the key's name, all-time spend, its credit limit and how often
  it resets, whether that limit includes your own provider keys, spend through
  your own provider keys, free-model requests today, free tier, and when the
  key expires.
- **xAI:** your balance, how much credit you bought, and how much of it is
  spent.
- **TypeSafe:** the price, and every model your key can use with its
  description and release date.
- **A key the provider refused** shows the whole error and where to replace
  the key.

One API row is open at a time, independently of the provider cards. Nothing
changes until you open a row, and keys stay in the macOS Keychain, sent only
to the provider that issued them.
