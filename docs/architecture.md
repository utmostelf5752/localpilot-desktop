# LocalPilot Desktop Architecture

LocalPilot Desktop is a macOS-only native app. The first implementation is a SwiftUI app with AppKit where macOS window behavior is required.

## Implemented Now

- XcodeGen project scaffold in `project.yml`.
- Native macOS app target named `LocalPilotDesktop` with bundle identifier `com.localpilot.desktop`.
- Full app window with sidebar, chat panel, inspector, and log snippets.
- Milestone 1 fake Agent Mode:
  - user enters a task and presses Start;
  - app enters `running`;
  - transparent always-on-top AppKit overlay window shows a haze, fake cursor, and floating controls;
  - Pause freezes the fake loop and disables the executor flag;
  - Continue accepts an optional instruction and resumes;
  - Stop cancels the loop immediately, disables execution, clears queued fake work, and exits Agent Mode.
- Local JSONL event logging at Application Support: `LocalPilot Desktop/logs.jsonl`.
- Core module placeholders under `core/agent` for orchestrator, planner, guard, state, context, policy, executor, providers, and logging.
- Internal model integration:
  - default in-process planner and guard providers run without Ollama or a
    separately configured runtime;
  - the internal planner emits one structured action at a time for smoke-run
    verification;
  - the internal guard returns JSON allow/deny decisions through the same guard
    adapter as future model backends.
- Optional managed local model runtime integration:
  - runtime executable path, planner model file, guard model file, host, port, launch arguments, health path, and completion path are configurable in Settings;
  - LocalPilot starts the runtime process itself with `Process`;
  - planner and guard calls go through a narrow localhost JSON endpoint;
  - Stop, blocked, done, and connection-test cleanup terminate the managed runtime through `ModelSessionManager`.
- Planner and guard adapters that request JSON-only model output and decode structured actions/guard decisions.
- Settings persistence for provider mode, runtime executable/model paths, planner model, guard model, runtime endpoint details, context window, temperature, timeout, scopes, guard enablement, and dry-run mode.
- Model cleanup through `ModelSessionManager`; registered providers cancel active requests and stop their managed runtime when Stop or task completion/blocked cleanup runs.

## Control Boundary

The model must never call operating-system APIs, shell commands, mouse events, keyboard events, file APIs, websites, or clipboard APIs. Future model providers may only return one structured action. LocalPilot validates that action, classifies it with deterministic policy, asks for native user approval when needed, optionally sends it to a guard model, and only then passes it to the executor.

## Control Loop

1. User enters a task.
2. Orchestrator captures current context.
3. Planner proposes exactly one structured action.
4. Schema validator validates the action.
5. Deterministic policy engine returns `allow`, `ask_user`, or `block`.
6. Native approval UI handles `ask_user`.
7. Guard model returns `allow` or `deny`; it cannot override policy blocks.
8. Executor performs one action if allowed.
9. State manager records result and logs the event.
10. Loop repeats until done, paused, stopped, or blocked.

## Stubbed Or Restricted For Later

- ScreenCaptureKit screenshot capture.
- Accessibility / AXUIElement observation.
- CGEvent / Quartz real input execution.
- Browser URL/domain detection.
- Bundled model weights and a bundled LocalPilot model runner binary. The app now owns the runtime lifecycle, but the executable and model files must be supplied in Settings until a runner is packaged.
- LM Studio, MLX, llama.cpp, and generic OpenAI-compatible compatibility adapters.
- Real context compaction persistence files beyond the documented interfaces.
- Non-dry-run OS execution. Current execution is intentionally dry-run unless later permissioned executors are added.
