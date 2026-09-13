# Reserve 1.3.2

This release keeps Claude and Grok connected between sign-ins.

- Claude connects and stays connected. When its saved sign-in is about to
  expire, Reserve asks Claude Code to renew its own session instead of asking
  you to sign in again.
- Grok no longer disconnects every few hours. Reserve asks the Grok CLI to
  renew its own session when the saved one is close to expiring.
- A sign-in you completed in the browser is now recognised even when the
  provider's helper ends with an error. Reserve checks your usage before it
  says the sign-in did not finish.
- Claude's sign-in no longer reports a stray "Invalid code" while connecting.

Browser sign-in is still needed when there is nothing left to renew, or when a
renewal is refused. Reserve never writes a provider's credentials: renewal is
performed by the provider's own helper, and Reserve reads the result from that
helper's own store.
