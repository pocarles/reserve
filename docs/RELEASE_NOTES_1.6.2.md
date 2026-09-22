# Reserve 1.6.2

Reserve does less repeated work and recovers from temporary failures with less intervention.

## Less background work

- Local history reuses its decoded index and watches enabled session folders for changes. Unchanged history no longer needs a full directory walk on each scan.
- Long scans save bounded progress and resume without presenting partial totals as freshly measured.
- Each provider follows its own refresh schedule. A failing provider backs off without making healthy providers refresh early.
- Automatic refresh pauses while offline or in Low Power Mode and resumes due providers when conditions recover. Manual refresh remains available.

## More reliable recovery

- Keychain reads run silently in the background. A temporarily locked Keychain no longer appears to be a missing key.
- Saving and removing keys waits for the result. Failed removals preserve the saved-key state, and canceled requests cannot restore old readings or re-enable a provider.
- Slow history scans and service-status checks no longer keep a completed quota refresh spinning.
- Sharing Claude's status line is more reliable when other command-line tools are running.

## Smoother updates

- Dashboard and Settings readings update existing controls. Typing, focus, and unsaved key drafts survive refreshes.
- Expanded details and charts update with their readings, including changes to Hide personal info.
- Automated checks now enforce memory, update-time, and rebuild budgets alongside recovery and connection tests.
