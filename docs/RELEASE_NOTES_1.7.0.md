# Reserve 1.7.0

Reserve can now track several Claude accounts side by side, for example a team
account next to a personal one, even when both use the same email address.
Open the Claude card in Settings > Providers and choose **Add Claude account**.
Reserve gives the account its own Claude Code folder under
`~/.claude-accounts/`, signs it in there, and leaves your first account
untouched. Each account gets its own card and dashboard tile, named after its
organization until you give it a name of your own. **Remove account** stops
tracking it and leaves its folder and sign-in on your Mac. Activity from this
Mac is not yet counted for added accounts.

Claude's status-line option is now **Also use Claude Code's status line in
Terminal**. It only receives updates while Claude Code runs in a terminal; the
Claude desktop app does not send them. With usage access allowed, Reserve now
keeps reading your limits directly and uses a recent status-line reading only
to update sooner, so turning the option on no longer stops updates.

Settings now opens on the screen you are using and moves to your current
Space instead of staying where it was last left.
