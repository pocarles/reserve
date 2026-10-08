# Reserve 1.6.4

The provider overview now shows when each displayed allowance resets. Expanded
details also explain how much of your token usage comes from caching.

## Reset times at a glance

- Every provider tile shows the reset for the allowance used by its percentage
  and meter, without making the tile taller.
- Nearby resets use a countdown that updates each minute. Later resets show a
  weekday or date and your local time.
- Missing or expired reset times read "Next reset unknown".

## Clearer token history

- When cache data is available, expanded details show uncached input, cached
  input, cache writes, and output separately for the last 30 days.
- Estimated API cache savings compare cached reads with the full input rate.
  This is an API price comparison, not a saving on your subscription bill.
  Reserve omits the estimate when a cache read cannot be priced.
- OpenAI totals no longer count cache writes twice when they are already
  included in input tokens. Previously saved daily totals are corrected when
  the retained session data confirms that exact error.
- Claude activity is grouped by your Mac's local calendar day, including
  daylight saving changes. Saved history is adjusted where the original
  session data is still available.
- History repairs resume after an interruption and keep the previous published
  totals until the replacement data is ready. Archive-only history is retained.
