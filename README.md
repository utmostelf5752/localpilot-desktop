# LocalPilot Desktop

LocalPilot Desktop is a macOS-only local-first desktop AI agent. The goal is to
let local models observe the screen and act through a visible, interruptible,
guarded loop while the user remains in control.

The source of truth for the product is [goal.md](goal.md). Current progress and
milestones are tracked in [progress.txt](progress.txt).

## Build

Generate the Xcode project after adding or moving Swift files:

```sh
xcodegen generate
```

Run tests:

```sh
xcodebuild test -project LocalPilotDesktop.xcodeproj -scheme LocalPilotDesktop -destination 'platform=macOS'
```

Build the app:

```sh
xcodebuild build -project LocalPilotDesktop.xcodeproj -scheme LocalPilotDesktop -destination 'platform=macOS'
```

## Current Status

The app has a native SwiftUI/AppKit shell, guarded action loop scaffolding,
local-model provider plumbing, overlay controls, policy checks, approval flow,
logging, and a first real observation path that captures current app/window
metadata plus a screenshot payload for observe actions and planner context.

Non-observe OS control remains dry-run until the permissioned executor is
implemented.
