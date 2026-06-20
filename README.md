# LocalPilot Desktop (macOS)

LocalPilot Desktop is a macOS-only local-first desktop AI agent. The goal is to
let local models observe the screen and act through a visible, interruptible,
guarded loop while the user remains in control.

> The Windows version lives in a separate repo: **localpilot-windows**.

## Download

Grab the latest **`.dmg`** from the [**Releases**](../../releases/latest) page,
open it, and drag **LocalPilot Desktop** to Applications.

The build is not notarized, so on first launch macOS Gatekeeper will warn you.
Right-click the app → **Open** → **Open** (only needed once).

**Requirements:** macOS 14+, and a local model server running —
[Ollama](https://ollama.com) (`http://localhost:11434`) or
[LM Studio](https://lmstudio.ai) (`http://localhost:1234`). In the app's
Settings, pick your provider, set the base URL, click **Detect Models**, choose a
planner/guard model, then start a task.

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
internal in-process planner/guard mode, optional managed-runtime plumbing,
overlay controls, policy checks, approval flow, logging, and a first real
observation path that captures current app/window metadata plus a screenshot
payload for observe actions and planner context.

Click, double-click, safe typing, approved paste, copy, scroll, keypress, URL
opening, restricted terminal command, and app-switch execution are implemented
behind the dry-run toggle. Dry-run remains the default.

The default internal planner can complete simple three-step local tasks without
Ollama or another localhost model server: observe, perform one recognized
structured action, then finish.
