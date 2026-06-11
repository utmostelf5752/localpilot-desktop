# Roadmap

## Milestone 1: Native App Shell

Implemented in this run:

- app launches as a native macOS SwiftUI app;
- full main window exists;
- chat-style task input exists;
- Start enters Agent Mode;
- overlay haze and fake AI cursor appear;
- floating controls show current action, Pause, and Stop;
- Stop hard-stops the fake loop and disables execution;
- Pause freezes the fake loop;
- Continue accepts an optional instruction and resumes;
- events are logged locally;
- managed local model provider scaffolding is present, but real OS control remains dry-run.

## Milestone 2: Scripted Executor

Add hardcoded JSON actions for observe, click, type, scroll, and wait. Wire interruption points so Stop can interrupt immediately and Pause can interrupt at safe action boundaries.

## Milestone 3: Action Schema And Policy

Add full JSON validation, policy classification, native approval popups, and fake demonstrations of allow, ask-user, and block decisions.

## Milestone 4: Screen Observation

Add ScreenCaptureKit screenshots, active app/window detection, basic accessibility tree capture, and browser URL/domain detection where available.

## Milestone 5: Owned Local Model Runtime

Implemented now:

- configurable runtime executable path;
- configurable planner and guard model file paths;
- configurable localhost host, port, health path, completion path, launch arguments, and environment;
- process launch through `ProcessManagedModelRuntime`;
- non-streaming JSON generation through the configured local completion endpoint;
- cancellable provider task tracking;
- immediate runtime stop through `ModelSessionManager.closeLoadedModels()`;
- planner proposes exactly one JSON action.

Still later:

- package a default LocalPilot model runner binary and starter model files;
- generic OpenAI-compatible endpoint;
- invalid JSON retry once with schema correction prompt;
- LM Studio, MLX, and llama.cpp direct integrations.

## Milestone 6: Guard Model

Implemented for managed local JSON guard output. Guard receives current context, proposed action, and deterministic policy result. It can only allow or deny and cannot override deterministic blocks or grant human approval.

## Milestone 7: Context Compaction

Persist structured state, recent raw steps, compacted history, approvals, and logs. Compact at 80 percent context usage while preserving immutable safety policy and current state.

## Milestone 8: Terminal Support

Add restricted workspace-only terminal actions after policy enforcement is strong. Deletion remains blocked. Medium-risk commands require approval.

## Milestone 9: Polish

Add task history, richer logs, settings, permission scopes, model configuration, private mode, and stronger error handling.
