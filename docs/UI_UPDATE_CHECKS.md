# UI update checks

Reserve keeps the open dashboard and the visible Settings pane in place when a reading changes. Percentages, status text, the refresh spinner, and the menu-bar sample update on the controls already on screen. A provider or control that appears or disappears rebuilds the affected dashboard region. Theme changes rebuild the dashboard. Settings rebuilds its pane when its controls or appearance change.

Store notifications that arrive together become one UI pass on the next turn of the main run loop. That pass reads the store then, so it shows the latest reading. A hidden Settings window or a closed dashboard does not build a new tree until it is shown again. Closing Settings still drops its content view. Closing the dashboard drops the popover's tree.

Typing in a Settings field is left alone. Other rows still take new readings. If the set of controls has to change while a field is being edited, that rebuild waits until editing ends, then runs on the next main-run-loop turn. Unsaved key drafts survive that rebuild.

Saving a plan or API key shows Saving immediately, ignores a second click until the save finishes, and clears the field only after the key is stored. A failure leaves the field as it was. The alert does not repeat the key.

Outside the developer self-tests, Reserve tells the store about Low Power Mode and whether the network path is unavailable. Wake and becoming active still use the existing resume refresh.

## What the stress gate measures

`make stress-ui` runs `swift run Reserve --stress-ui`. It uses preview data and does not call a provider. After a warmup, it opens and closes the popover and Settings 30 times and requires physical footprint growth of at most 40 MB. It then leaves the dashboard open and applies eight cached readings. Every reopened dashboard must contain rendered content. The eight readings must not replace the dashboard or a provider region. A monotonic clock measures each pass until the dashboard records its completed content update, with a 1.5-second limit and a two-second wait deadline. The time bound is only there to catch a hitch. It is not a speed score.

The same target is part of `make check` and the pull-request CI job. One run, ten minute cap.

`make reliability-test` runs `swift run Reserve --self-test-reliability` with the same isolated defaults and per-process lock as the other developer self-tests. It exercises slow work, canceled requests, Keychain recovery, independent provider schedules, and offline recovery using injected fixtures.

## Identity coverage

`make lifecycle-test` includes a check that an exhausted reading keeps the dashboard view, the OpenAI tile, an unchanged tile, and the open card. It also types into the OpenAI subscription field and requires that text to remain while Grok's updated time changes. Additional fixtures verify live Settings preferences and heatmaps, deferred layout changes, expanded API privacy, component-share readings, permission guidance, and release of dashboard view trees.
