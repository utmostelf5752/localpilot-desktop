# macOS Permissions

Milestone 1 does not require real screen capture or computer control permissions because the overlay, fake cursor, and fake task do not read or control the user’s computer.

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
- Does not use ScreenCaptureKit.
- Does not use AXUIElement.
- Does not use CGEvent.
- Does not read clipboard contents.
- Does not access files except local JSONL logs in Application Support.
- Does not perform real mouse, keyboard, terminal, clipboard, file, or browser control; executor output is dry-run.
