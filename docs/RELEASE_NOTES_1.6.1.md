# Reserve 1.6.1

Reserve now shows every provider in one overview, restores the provider you last
opened, and puts its details below the grid.

## A clearer dashboard

- See every enabled provider at a glance, then select one tile for its full
  allowance, forecast, activity, and cost details.
- Reserve restores your last selected provider when you reopen the dashboard.
- Pin the selected provider to the menu bar from its detail panel. Automatic
  selection remains available in Settings.
- Local token totals include both input and output. Cached tokens now appear as
  one total, without a cache-write value that OpenAI does not report.
- The detail panel no longer repeats billing-cycle totals or local scan time.
  Scan errors still appear when Reserve cannot refresh local history.
- Manual refresh updates local usage history even when Insights is closed.

## Privacy and sharing

- **Hide personal info** masks account emails and organization names across
  Reserve. The setting is also available from the menu-bar menu.
- **Share usage** creates an image or text summary. Reserve excludes account and
  organization details, paths, raw errors, and provider-controlled labels.

## Faster access, quieter checks

- Choose a global shortcut in Settings > General to open the dashboard from
  any app. Shortcuts are off until you select one.
- Adaptive refresh checks every 2, 5, 15, or 30 minutes based on how recently
  you opened Reserve. Low Power Mode and high thermal pressure use the
  30-minute interval. Existing fixed refresh choices remain available.

## Better history

- Insights can compare the last 7, 30, or 90 days from Reserve's existing local
  history cache. Changing the range does not rescan session files.
- Daily heatmaps distinguish a quiet day from a missing day and show how much
  of the requested period is covered.
- Estimated API-equivalent value stays separate from subscription cost and is
  never presented as a bill.
