# Review: LocalPilot with Ollama / LM Studio

Comprehensive review (multi-agent, each finding adversarially verified) of the
real workflow when driving LocalPilot with **Ollama** or **LM Studio**: provider
detection, transport, what is actually passed to the model, and context usage.
**37 findings confirmed**, collapsing into **17 fixes** across 4 themes.

Root cause for most "critical" transport issues: the provider layer was built to
*launch and talk to a bundled `localpilot-model-runner` (llama.cpp-style) binary*,
not to *connect to an already-running Ollama/LM Studio server* — which is what the
product spec ([goal.md](../goal.md) lines 20, 592–610, 663–666) requires and what
the user actually wants.

## Status

- ✅ **Build-blocker fixed.** Committed `b8813a5` did **not compile**:
  `kAXLinkRole` is not a real SDK symbol ([ScreenObservation.swift:240](../core/agent/context/ScreenObservation.swift)).
  Changed to the literal `"AXLink"`. App now builds clean (0 errors) and the
  existing test suite is the baseline to protect.
- ⏳ Fixes 1–17 below are scoped and prioritized but **not yet applied**.

---

## THEME A — Transport: connect to a real server with the right shape (unblocks everything)

**Fix 1 — Provider kinds + base URL + connect-only runtime (KEYSTONE).**
Add `ModelProviderMode` cases `.ollama`, `.lmStudio`, `.openAICompatible` (keep
`internalInProcess` stub and `managedRuntime` self-spawned runner intact). Add
`runtimeBaseURL: URL` to `AppSettings` + `ManagedModelRuntimeConfiguration`. Add a
`ConnectOnlyModelRuntime` whose `ensureRunning` returns the base URL **without**
`isExecutableFile`/`process.run()`. Wire it into `makePlannerProvider`/
`makeGuardProvider` and `testModelRuntimeConnection`.
Files: `AppSettings.swift`, `ModelProvider.swift`, `AgentController.swift`.

**Fix 2 — Per-backend request/response shaping.**
- Ollama → `POST /api/generate`, body `{model, prompt, system?, stream:false,
  format:<"json"|schemaObject>, options:{temperature, num_ctx}}`; decode `{response}`.
- LM Studio / OpenAI → `POST /v1/chat/completions`, body `{model,
  messages:[{role:"system"…},{role:"user"…}], temperature,
  response_format:{type:"json_schema", json_schema:{name, schema, strict:true}}}`;
  decode `choices[0].message.content`. **Carry the schema `name`** (currently
  discarded at `case let .jsonSchema(_, schema)`).
Files: `ModelProvider.swift`, `AppSettings.swift` (drop `planner.gguf`/`guard.gguf`
defaults for connect modes). Update `ManagedLocalModelProviderTests` dual-key assertion.

**Fix 3 — Provider presets: ports, paths, tolerant health check.**
Ollama `http://localhost:11434` / `/api/generate` / liveness `GET /` (200);
LM Studio `http://localhost:1234` / `/v1/chat/completions` / liveness `GET /v1/models`.
Make `healthCheck`/`waitUntilHealthy` accept any 2xx from the configured liveness
path (no dedicated `/health`). Replaces the fictional `/v1/localpilot/complete`
(404) and `/health` (404 on Ollama) defaults and the wrong port 49191.

**Fix 4 — Settings UI: backend picker + base URL field.**
Picker auto-gains the new modes; add a Base URL field shown for connect modes,
hide the `.gguf`/executable/launch-args fields for them. High-value optional:
a model picker populated from `GET /api/tags` (Ollama) / `GET /v1/models` (LM Studio).
File: `MainWindowView.swift`.

**Fix 5 — Send `num_ctx`; reconcile compaction budget; correct unload.**
Add `options["num_ctx"] = contextWindowSize` on the Ollama body. Lower default
`contextWindowSize` 131072 → ~8192 and drive **both** `num_ctx` and the compactor
budget from it (today the 80% threshold of 131072 never fires for small models).
For Ollama connect mode, `closeModel()` should POST `{model, keep_alive:0}` to
unload — not kill a process the app never spawned.

**Fix 6 — Code-fence/JSON-extraction sanitizer + one schema-correction retry.**
Local models wrap JSON in ```` ```json ```` fences / prose; strict
`Data(response.utf8)` decode fails. Add a shared `extractJSON(_:)` (strip fences,
slice first balanced `{…}`/`[…]`) at the three decode sites
([Planner.swift:41,59](../core/agent/planner/Planner.swift),
[GuardModel.swift:42](../core/agent/guard/GuardModel.swift)). On first decode
failure, issue **exactly one** correction retry (Milestone 5 requirement), then
fail safe. Highest leverage for actual task success on small models.

## THEME B — Executor wiring (the product is currently inert / unsafe)

**Fix 7 — Wire `dryRunExecutionOnly` into the executor.**
`dryRun` is a `private let` set once at init; `AgentController` never passes
`settings.dryRunExecutionOnly`. The toggle does **nothing** — the app is
permanently dry-run. Make `dryRun` mutable + `setDryRun(_:)` on the protocol; call
it before the loop.

**Fix 8 — Re-enable executor on `start()`.**
`stop()` sets the actor's `enabled=false`; only `continueTask`'s `setPaused(false)`
ever flips it back. So **every task after the first Stop returns "Executor
disabled."** Re-enable in `start()`.

**Fix 9 — Close the post-Stop execution window (gate before Fix 7 goes real).**
Actor-reentrancy: a validated action can be enqueued on the executor before
`stop()` runs. Gate real execution behind a per-run token the controller
invalidates synchronously in `stop()`.

## THEME C — Policy false-positives (workflow friction)

**Fix 10 — Token/word matching instead of substring.**
`riskyClickTerms` substring match fires approval on "Posts"/"Postal code"/"Runner
up". `dangerousCommandFragments` substring match **blocks** safe commands via
`.env`/`/var/`/`find `/`history`/`export `/`env `. Tokenize; split destructive
(stay `block`) vs unknown-inspection (downgrade to `ask_user`). Keep `.env` blocked
(spec-mandated).

## THEME D — Context layering & cleanups (quality, after core works)

- **Fix 11** — Planner gets no `recentMessages` and no Continue instruction
  (`continueInstructions` is write-only) → paused-and-corrected runs loop on the
  same blocked action. Render a bounded message tail + fold the latest instruction
  into the task.
- **Fix 12** — Inject permission scope + `deniedActions` (+ populate
  `userApprovals`, never appended today) into the planner context per the
  layered-context spec.
- **Fix 13** — Stop base64-encoding the full-display PNG every observation; it
  never reaches any prompt (providers are text-only). Return dimensions only.
- **Fix 14** — `ModelSessionManager.providers` grows by 2 per run when unload is
  off; drain it in `start()`.
- **Fix 15** — Per-item char cap on `accessibilitySummary` (matches element-label cap).
- **Fix 16** — `switch_app` trusts planner `risk_level` and shells out to
  `open -a` (bypasses terminal policy); classify against `allowedApps` and use
  `NSWorkspace.openApplication`.
- **Fix 17** — Optionally pre-seed `allowedDomains` from URLs in the task and
  populate `currentDomain` so redirects to unapproved domains can pause.

## Recommended landing order

1. Fix 1 (keystone) → 2. Fix 2 + 3 → 3. Fix 6 → 4. Fix 5 → 5. Fix 4 (UI)
→ 6. Fix 11 (parallel) → 7. Fix 9 → 7 → 8 (land the safety gate before real
execution) → 8. Fix 10 → 12/16/17 → 13/14/15.

**Protect existing behavior:** keep `internalInProcess` (stub) and `managedRuntime`
(self-spawned runner, `/v1/localpilot/complete` body, Process-kill unload) as their
own branches; gate all new behavior behind the new provider kinds. Two tests lock
current behavior and must be updated: `ManagedLocalModelProviderTests` (dual-key
schema body) and the dry-run executor tests.
