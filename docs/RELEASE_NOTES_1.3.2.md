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
- The headline names the plan that runs out soonest, not the one furthest off
  pace, and says how many others are at risk. It no longer leads with "no pace
  forecast yet" while every other plan is fine.
- Setup and permission actions are no longer orange. Orange now means one thing
  only: an allowance that may run out or is out.
- A reset less than twelve hours away is shown as a countdown — "resets in
  1h 20m" — instead of a clock time you have to work out.
- The pace marker on each meter now says what it is: the capacity that should
  remain at this point in the window.
- Estimated values are marked as estimates, so "≈ $9,995" is never mistaken for
  a billed amount.
- Provider buttons name the action they perform — Sign in, Allow access, Set up,
  Update — instead of a generic Connect or Reconnect.
- Windsurf support was removed. Reserve could only read a plan record that Devin
  Desktop wrote while its own plan settings were open, and current Devin builds
  no longer show that section, so the saved numbers could never be brought up to
  date. Its card, settings row, and saved usage are gone; the other five
  providers are unchanged.

Browser sign-in is still needed when there is nothing left to renew, or when a
renewal is refused. Reserve never writes a provider's credentials: renewal is
performed by the provider's own helper, and Reserve reads the result from that
helper's own store.
