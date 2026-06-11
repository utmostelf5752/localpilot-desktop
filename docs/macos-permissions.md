# macOS Permissions

LocalPilot now has real observation and guarded control paths. Dry-run remains
the default, so a normal first launch can inspect the loop without moving the
mouse, typing, opening URLs, switching apps, touching the clipboard, or running
commands.

## Future Permissions

Accessibility:
Required for AXUIElement UI observation and semantic control of accessible apps. The app must explain why access is needed and keep control visible and interruptible.

Screen Recording:
Required for ScreenCaptureKit screenshots or screen observation. Screenshot persistence must be configurable: store screenshots, store only hashes, or private mode with no screenshot persistence.

Input Monitoring / Quartz Events:
May be required for future keyboard/mouse event execution. Real input execution must remain behind the structured action, policy, guard, and approval pipeline.

Automation:
May be needed for app-specific control or browser automation. Automation scopes should be narrow and task-specific.

## Current Implementation

- Uses an AppKit borderless overlay window for visual haze, fake cursor, and controls.
- Runs the default internal planner/guard provider in-process without Ollama or a localhost runtime.
- In optional managed-runtime mode, starts a configured local model runtime executable and talks to it over localhost for planner and guard models.
- Stops the configured model runtime after connection tests, Stop, blocked runs, and completed runs when model unloading is enabled.
- Captures a screenshot payload for observe actions.
- Uses AXUIElement summaries when Accessibility permission is granted, and
  reports a clear fallback when it is not granted.
- Uses CGEvent for approved mouse, keyboard, scroll, copy, and paste actions
  only when dry-run is disabled.
- Does not read clipboard contents.
- Can set approved paste text onto the clipboard before posting paste.
- Does not access files except local JSONL logs in Application Support.
- Can open approved URLs, switch apps, and run restricted terminal commands
  after deterministic policy, optional user approval, guard review, and the
  executor dry-run gate.
