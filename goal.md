You are building a macOS-only open-source desktop AI agent app called LocalPilot Desktop.

Use:
- Product name: LocalPilot
- Full app name: LocalPilot Desktop
- Repo/package name: localpilot-desktop
- Bundle identifier: com.localpilot.desktop
- CLI name, if added later: localpilot

Goal:
Build a native macOS app that lets a local AI model control the user’s computer in a visible, interruptible, guarded way.

The app should look like a normal AI chat app. The user gives a task in chat. When the agent starts working, the app enters Agent Mode: the screen gets a haze overlay, a fake AI cursor overlay appears, and Pause/Stop buttons stay visible at all times.

The AI may control the computer only through structured actions. It must never directly access OS APIs, shell commands, mouse movement, keyboard input, files, websites, or the clipboard. The model proposes one structured action. The app decides whether to execute it.

Do not make this a menu bar app. Build a full macOS app.

Core concept:
LocalPilot is a local-first macOS desktop agent. It uses local models through Ollama, LM Studio, llama.cpp, MLX, or a generic OpenAI-compatible local endpoint. It has a planner model for deciding actions, a guard model for safety checks, and a deterministic policy engine that enforces non-negotiable rules before anything touches the computer.

The user must always remain in control.

Required UX:
1. Main app window with a chat interface.
2. User enters a task.
3. Agent enters Agent Mode.
4. Haze overlay appears on the screen.
5. Fake AI cursor shows where the agent intends to act.
6. Floating overlay shows:
   - Current action
   - Pause button
   - Stop button
7. Agent acts one step at a time.
8. Risky actions trigger native approval popups.
9. User can pause, manually do something, add an instruction, and continue.
10. User can stop at any time. Stop must hard-stop the agent.

Important macOS details:
- macOS has only one real system cursor.
- The “AI cursor” should be a visual overlay, not a second real cursor.
- In v1, the agent may move the real cursor while the fake AI cursor shows intent.
- Later versions can use more semantic control through Accessibility APIs or browser DOM automation.
- Use ScreenCaptureKit for screen observation if possible.
- Use macOS Accessibility / AXUIElement APIs for reading accessible UI elements.
- Use CGEvent / Quartz Event Services for mouse and keyboard events.
- Use a transparent always-on-top NSWindow for the haze, cursor, and controls.

Recommended architecture:

localpilot-desktop/
  apps/
    macos/
      LocalPilotDesktop.xcodeproj or Swift Package app
      Sources/
        App/
        UI/
        Chat/
        Overlay/
        Permissions/
        Control/
        Models/
  core/
    agent/
      orchestrator/
      planner/
      guard/
      state/
      context/
      policy/
      executor/
      providers/
  docs/
    architecture.md
    safety-policy.md
    action-schema.md
    context-compaction.md
    macos-permissions.md
    roadmap.md
  examples/
    tasks/
  tests/

If the current repo is empty, create this structure.
If files already exist, inspect them first and do not delete anything.

Platform:
- macOS only for v1.
- Native app preferred.
- Use SwiftUI/AppKit for the main app and overlay.
- The agent core can be Swift, TypeScript, or Python, but keep it modular.
- Choose the simplest implementation that can actually run.
- Do not require cloud APIs.
- Local model providers should be pluggable.

Main app layout:
- Full desktop app window.
- Chat interface like a normal AI app.
- Sidebar:
  - New task
  - Past tasks
  - Settings
  - Permissions
  - Logs
- Main panel:
  - User messages
  - Agent messages
  - Action cards
  - Approval cards
  - Log snippets
- Optional inspector panel:
  - Current state
  - Active app/window
  - Current URL/domain if available
  - Allowed apps/domains/folders
  - Last actions
  - Guard decisions
  - Context usage

Agent Mode overlay:
- Transparent haze around the screen.
- Fake AI cursor overlay.
- Floating controls:
  - Current action label
  - Pause
  - Stop
- Overlay states:
  - idle
  - running
  - paused
  - approval_required
  - stopping
  - stopped

Example overlay labels:
- “Observing screen”
- “Clicking Search”
- “Typing query”
- “Waiting for page load”
- “Approval required”
- “Paused”
- “Stopping”

Stop behavior:
Stop is a hard stop. It must not depend on asking the model to stop.

When Stop is pressed:
- Immediately disable the executor.
- Cancel the current model request if possible.
- Clear all queued actions.
- Cancel the action loop.
- Release keyboard/mouse control.
- Hide overlay after cleanup.
- Mark task as stopped.
- Best-effort unload model or close the model session if the backend supports it.
- Never allow another action to execute after Stop is pressed.

Pause behavior:
Pause is a soft interrupt.

When Pause is pressed:
- Stop the action loop at the safest boundary possible.
- Cancel or suspend current generation if possible.
- Keep task state.
- Keep logs.
- Disable the executor while paused.
- Let the user use the computer manually.
- Show a paused overlay with:
  - Continue button
  - Stop button
  - Optional instruction textbox

When Continue is pressed:
- Capture a fresh screenshot/state.
- Include the user’s new instruction if provided.
- Resume with:
  - Original task
  - Immutable safety policy
  - Current permission scope
  - Current structured state
  - Compacted history
  - Recent raw history
  - Latest screen state
  - User’s continue instruction

Pause should happen at action boundaries when possible:
- after click
- after type chunk
- after scroll
- after wait
- after terminal command completes
- after observation

Stop must work even mid-action.

Critical safety principle:
The AI model must never directly control the computer. It may only propose structured actions.

Required control loop:
1. User enters task.
2. App captures current screen/app/window/URL/accessibility state.
3. Planner model proposes exactly one structured action.
4. Action schema validator validates the model output.
5. Deterministic policy engine classifies the action as allow, ask_user, or block.
6. If ask_user, show native approval popup.
7. Guard model reviews the action and context and returns allow or deny only.
8. Executor performs the action only if allowed.
9. App captures the result.
10. State manager updates state and logs.
11. Repeat until task is done, paused, stopped, or blocked.

The planner may propose either a single action or a short ordered plan
({"actions":[ ... ]}, up to 6 steps). Plans are proposals only: the orchestrator
re-validates each action (policy + guard), executes them one at a time,
re-observes between steps, and aborts the rest of the plan to re-plan if a step
fails. Stop and Pause are honored between every action. Ungated batches are
never executed directly.

Action schema:
The planner may only output one of these action types:
- observe
- click
- double_click
- type_text_safe
- type_text_sensitive
- press_key
- scroll
- copy
- paste
- open_url
- run_terminal_command
- switch_app
- wait
- finish
- ask_user

Every action must include:

{
  "type": "...",
  "target_kind": "...",
  "target_text": "...",
  "coordinates": [x, y] or null,
  "text": "exact text if typing/pasting, else null",
  "command": "exact terminal command if terminal, else null",
  "expected_result": "...",
  "risk_level": "low | medium | high",
  "reason": "..."
}

The planner’s reason is not trusted.
The policy engine and guard must inspect the raw fields directly:
- action type
- coordinates
- target text
- exact typed text
- exact pasted text
- exact terminal command
- app name
- window title
- URL/domain
- active field type
- visible screen text
- accessibility/HTML metadata

Click safety:
Click actions should include:
- target kind
- visible target text
- coordinates
- expected result
- risk level

Before executing a click, verify when possible that the coordinate roughly matches the intended visible element or AX element.

Risky click targets require approval:
- Submit
- Send
- Delete
- Remove
- Confirm
- Purchase
- Checkout
- Install
- Run
- Allow
- Grant access
- Continue on login, payment, permission, or destructive pages

Typing safety:
Typing is split into:
- type_text_safe
- type_text_sensitive

Safe typing examples:
- search query in a known search field
- non-sensitive note text
- fake/test data in a sandbox form

Sensitive typing examples:
- password fields
- email fields
- name fields
- phone fields
- address fields
- payment fields
- login forms
- terminal input
- messages
- emails
- unknown domains
- personal information
- API keys
- tokens
- secrets

In v1, the agent must never enter personal information automatically.

If a form asks for personal information, the agent should pause and ask the user to fill it manually or ask for explicit approval if the settings later allow it. Default behavior should be block or ask, not allow.

Enter key safety:
Pressing Enter can submit forms, send messages, run commands, or confirm destructive actions.

Allow Enter automatically only in clearly safe contexts like search fields.

Require approval for Enter in:
- Terminal
- chat boxes
- message boxes
- email compose boxes
- forms
- checkout pages
- login pages
- destructive confirmation dialogs

Clipboard safety:
Clipboard access is dangerous.

Rules:
- Do not read the existing clipboard by default.
- Pasting existing clipboard requires approval.
- Copying visible non-sensitive page text can be allowed.
- Copying secrets, tokens, private messages, or files requires approval or block.
- Pasting generated safe text into a known safe field can be allowed.
- Streaming typed text is still typing. Treat it with the same policy as paste.

Terminal support:
Terminal can exist in v1, but must be heavily restricted.

Allowed without approval:
- pwd
- ls
- cd within approved workspace
- cat files inside approved workspace
- git status
- git diff
- git log
- npm test
- npm run build
- python scripts inside approved workspace if non-destructive
- node scripts inside approved workspace if non-destructive

Requires approval:
- npm install
- pip install
- brew install
- git commit
- git push
- creating files
- moving files
- network commands
- editing config files
- running unknown scripts
- any command outside the workspace

Blocked:
- rm
- rm -rf
- sudo
- chmod -R
- chown -R
- curl | sh
- wget | sh
- dd
- mkfs
- diskutil erase
- shutdown
- reboot
- killing system processes
- reading ~/.ssh
- reading Keychain
- reading browser profiles
- reading .env files unless explicitly approved
- commands outside the approved workspace
- deleting files

Important v1 rule:
The user said the agent should never delete files. Implement deletion as blocked by default.

Website/domain safety:
The agent must never visit websites that were not specifically mentioned or approved by the user.

Implement a domain allowlist.

Examples:
- User says “go to Amazon and compare Logitech G29 prices.”
- Allowed: amazon.com
- Block or ask before visiting unknown domains.
- Pause if redirected to an unknown domain.
- Block URL shorteners unless explicitly approved.
- Block payment, banking, and credential pages unless the user explicitly navigates manually and approves.

Personal information safety:
The agent never enters personal information in v1.

Personal information includes:
- name
- address
- phone number
- email
- password
- payment information
- government ID
- health information
- private account information
- credentials
- tokens
- API keys
- private messages

If the agent encounters a form asking for this:
- pause and ask the user to handle it manually
- or ask for explicit approval only if a future setting allows it

Default: do not autofill personal information.

Deterministic policy engine:
The deterministic policy engine runs before the guard model.

It classifies actions as:
- allow
- ask_user
- block

The policy engine is the main safety boundary.
The guard model is extra judgment, not the only protection.

Example deterministic policy:
- deletion: block
- unapproved website: block or ask_user
- dangerous terminal command: block
- medium-risk terminal command: ask_user
- password field typing: ask_user or block
- payment field typing: block
- click submit/send/purchase: ask_user
- safe search query: allow
- scroll/wait/observe: allow

Guard model:
The guard model receives:
- original task
- immutable policy
- current permission scope
- current app
- current window title
- current URL/domain
- latest screenshot or screenshot reference
- visible text/OCR
- relevant accessibility/HTML info
- active field info
- recent actions
- proposed action with raw fields
- deterministic policy result
- risk flags

Guard output must be only:

{
  "decision": "allow" | "deny",
  "reason": "short reason"
}

The guard:
- cannot create actions
- cannot modify policy
- cannot override deterministic blocks
- cannot approve actions that require human approval
- should deny if context is insufficient
- should inspect raw action fields, not just the planner’s reason

Approval popup:
Native popup must show:
- exact action
- target app/domain
- text/command if any
- risk explanation
- buttons:
  - Allow once
  - Deny

Optional future feature:
- Always allow this narrow category for this task

Avoid broad approvals like:
- Always allow clicks
- Always allow terminal
- Always allow paste

Good narrow approvals:
- Always allow typing non-sensitive search queries on amazon.com for this task
- Always allow clicking search results on amazon.com for this task

Context compaction:
Implement context compaction because screenshots, OCR, accessibility trees, and action logs can fill the context window quickly.

Context should be layered:
1. Immutable safety policy, never summarized.
2. Original user task, never summarized.
3. Permission scope, never summarized.
4. User approvals and denials, never summarized.
5. Current structured state, never summarized.
6. Compacted old history.
7. Recent raw history.
8. Latest observation.
9. Proposed action.

Compaction rule:
When estimated context usage reaches 80 percent of the configured model context window:
- summarize the oldest 80 percent of history
- keep the newest 20 percent raw
- always inject original task directly
- always inject immutable safety policy directly
- always inject current permissions directly
- always inject denied actions directly
- always inject user approvals directly
- always inject current structured state directly
- never let the planner edit immutable policy

Do not rely only on natural-language summaries.
Use a structured state object as the source of truth.

Store:
- state.json
- recent_steps.jsonl
- compacted_history.md
- approvals.jsonl
- logs.jsonl

State object example:

{
  "task_id": "...",
  "original_task": "...",
  "current_subtask": "...",
  "status": "running | paused | stopped | done | blocked",
  "allowed_domains": [],
  "allowed_apps": [],
  "allowed_folders": [],
  "completed_steps": [],
  "known_facts": {},
  "open_risks": [],
  "denied_actions": [],
  "user_approvals": [],
  "last_observation_summary": "...",
  "last_action_result": "..."
}

Logging:
Every step must log:
- timestamp
- task id
- active app
- active window
- URL/domain if browser
- observation summary
- proposed action
- deterministic policy decision
- user approval/denial if any
- guard decision
- executor result
- screenshot reference or hash
- state update

Logs are local only.

Screenshot storage should be configurable:
- store screenshots
- store only hashes
- private mode with no screenshot persistence

Model layer:
Support local model endpoints:
- Ollama
- LM Studio
- generic OpenAI-compatible local endpoint
- later MLX
- later llama.cpp direct support

Model roles:
- Planner model: proposes actions
- Guard model: allow/deny safety review
- State manager/summarizer model: compacts history

Planner can be larger.
Guard should be small and fast.
State manager can be small.

The model provider interface should support:
- provider name
- base URL
- model name
- context window size
- temperature
- timeout
- cancellation
- streaming if available

Required cancellation:
Model calls must be cancellable so Stop and Pause can interrupt them.

Implementation order:

Milestone 1: Native app shell
- Native macOS app launches.
- Full app window exists.
- Chat interface exists.
- User can type a task.
- User can start a fake task.
- App enters Agent Mode.
- Haze overlay appears.
- Fake AI cursor appears.
- Floating Pause/Stop controls appear.
- Stop exits Agent Mode immediately.
- Pause changes overlay to paused state.
- Continue accepts optional instruction.
- Events are logged.

Milestone 2: Scripted executor
- Add hardcoded JSON actions.
- Move cursor.
- Click.
- Type.
- Scroll.
- Wait.
- Stop can interrupt.
- Pause can interrupt at action boundaries.
- No model yet.

Milestone 3: Action schema and policy engine
- Add action schema validation.
- Add deterministic policy engine.
- Add allow/ask_user/block classification.
- Add native approval popup.
- Demonstrate allow/ask/block on fake actions.

Milestone 4: Screen observation
- Capture screenshot.
- Get active app/window.
- Get basic accessibility tree.
- If browser URL detection is available, capture URL/domain.
- Add observation object.

Milestone 5: Local model provider
- Add model provider interface.
- Support Ollama.
- Support generic OpenAI-compatible endpoint for LM Studio.
- Planner proposes one JSON action.
- Validate JSON.
- If invalid, retry once with a schema correction prompt.
- If still invalid, fail safely.

Milestone 6: Guard model
- Add guard model provider.
- Guard receives context and proposed action.
- Guard returns allow/deny only.
- Denial reason is passed back to planner in a short form.
- Guard cannot create actions.

Milestone 7: Context compaction
- Track estimated token/context usage.
- Compact when usage reaches 80 percent.
- Keep newest 20 percent raw.
- Preserve immutable policy, original task, permissions, approvals, denied actions, and current state.

Milestone 8: Terminal support
- Add terminal actions only after policy engine is strong.
- Workspace-only.
- Deletion blocked.
- Dangerous commands blocked.
- Medium-risk commands require approval.

Milestone 9: Polish
- Task history.
- Better logs.
- Settings.
- Permission scopes.
- Model configuration.
- Private mode.
- Better error handling.

Deliverables for this Codex run:
1. Inspect the current repo.
2. Do not delete existing files.
3. Create docs/architecture.md with the full architecture.
4. Create docs/safety-policy.md with deterministic policy rules.
5. Create docs/action-schema.md with JSON schemas.
6. Create docs/context-compaction.md explaining the 80/20 compaction system.
7. Create docs/macos-permissions.md explaining required macOS permissions.
8. Create docs/roadmap.md with milestones.
9. Scaffold the app if possible.
10. Implement Milestone 1 if the environment supports macOS/Swift.
11. If the environment cannot build macOS UI, create the docs and project skeleton, then explain what must be done locally in Xcode.

Coding standards:
- Keep code simple and modular.
- Keep safety policy separate from model prompts.
- Every action must go through one executor interface.
- Every model output must be schema-validated.
- Every action must be logged.
- Stop/Pause controller must be independent from the model.
- The model must never call shell or OS APIs directly.
- No deletion features in v1.
- No personal info autofill in v1.
- No unapproved domains in v1.
- One action executed at a time: planned multi-action is allowed, but each
  action is independently gated and executed one at a time, never as an ungated
  batch.
- Prefer explicit state machines over loose flags.
- Prefer structured JSON over natural language where possible.
- Fail closed when uncertain.

Important behavior:
If context is insufficient, ask the user or observe again.
If the action is risky, ask the user.
If the action is blocked, explain why and ask the planner to choose a safer alternative.
If the model produces invalid JSON, retry once.
If still invalid, stop safely.
If Stop is pressed, nothing else may execute.
If Pause is pressed, do not continue until the user clicks Continue.

When finished, report:
- What was created
- What works
- What is stubbed
- How to run it
- What permissions are needed
- What the next Codex task should be
---

## Feature Loop (read first, for scheduled autonomous runs)
You are an autonomous dev agent working on this project on a schedule. Each run:
1. Read this file (the spec above is your north star).
2. Pick the single highest-value unchecked item from the Backlog below.
3. Implement it. Build it (xcodebuild) and fix anything you break.
4. Move the finished item to Done with a one-line note and today's date.
5. Add 1-3 new feature or improvement ideas to Backlog for the next run.
Keep each run's diff small and shippable. Never leave the build broken.

## Backlog
- [ ] Chat window shell with task input field.
- [ ] Agent Mode: transparent always-on-top haze overlay.
- [ ] Fake AI cursor overlay showing intended action location.
- [ ] Floating controls overlay with Pause and Stop buttons.

## Done
