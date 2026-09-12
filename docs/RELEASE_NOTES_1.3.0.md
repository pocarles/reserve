# Reserve 1.3.0

## A clearer everyday view

- See the useful answer first: what remains, when it resets, and whether your
  current pace will last.
- Open one provider when you want the details. Empty rows and secondary metrics
  stay out of the way.
- Keep reset times, freshness labels, accessibility text, and pace markers
  current while the dashboard is open.
- Show richer plan and account details only when the provider reports them.

## Easier, more reliable connections

- Preserve provider choices across updates and enable only helpers already
  present on a new Mac.
- Reuse Cursor plan metadata and request detailed history only when Insights is
  opened.
- Adopt a renewed Grok session when another Grok client refreshes it.
- Optionally receive Claude limits from Claude Code's documented status line,
  without reading its sign-in. Updates arrive after Claude Code responds.

## More providers and better data

- Add experimental GitHub Copilot quota support through the installed Copilot
  CLI. It starts disabled and still needs testing against a signed-in paid
  account.
- Show named OpenAI allowance buckets, available reset credits, and optional
  account activity. Reserve never spends a reset credit.
- Treat Windsurf's saved allowance as age unknown instead of presenting the time
  Reserve checked the cache as the time Windsurf observed it.

## Lighter background work

- Check at most two providers at once during a normal refresh.
- Skip account-history requests until Insights needs them.
- Replace byte-by-byte HTTP processing with bounded chunked reads.
- Debounce passive quota-file updates and add tolerance to background timers.

Claude subscription usage could not be tested because no paid Anthropic account
was available. Copilot could not be tested because its CLI and paid account were
not available. Both paths passed their fixture, cancellation, size-limit, and
native connection-flow tests.
