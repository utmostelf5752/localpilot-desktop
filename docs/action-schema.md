# Action Schema

Planner output must be exactly one action. Natural-language reasoning is not trusted. Policy and guard inspect raw fields.

## Supported Action Types

- `observe`
- `click`
- `double_click`
- `type_text_safe`
- `type_text_sensitive`
- `press_key`
- `scroll`
- `copy`
- `paste`
- `open_url`
- `run_terminal_command`
- `switch_app`
- `wait`
- `finish`
- `ask_user`

## JSON Shape

```json
{
  "type": "click",
  "target_kind": "button",
  "target_text": "Search",
  "coordinates": [420, 310],
  "text": null,
  "command": null,
  "expected_result": "Search results appear",
  "risk_level": "low",
  "reason": "The user asked to search"
}
```

## Required Fields

- `type`: one supported action type.
- `target_kind`: UI, app, browser, terminal, or semantic target category.
- `target_text`: visible target text when available.
- `coordinates`: `[x, y]` or `null`.
- `text`: exact text for typing or pasting, else `null`.
- `command`: exact terminal command, else `null`.
- `expected_result`: expected observable result.
- `risk_level`: `low`, `medium`, or `high`.
- `reason`: planner explanation, treated as untrusted.

## Validation Rules

- Reject arrays with more than one action.
- Reject unknown action types.
- Reject missing raw fields.
- Reject invalid risk levels.
- Reject terminal actions without `command`.
- Reject typing and paste actions without exact `text`.
- Reject invalid URLs before policy classification.

## Implemented Now

Swift structured types exist in `core/agent/policy/ActionSchema.swift`. Planner
JSON decoding accepts model output without an internal UUID and generates one
locally. Batch rejection, deterministic policy rules, internal in-process task
planning, managed local model request shaping, runtime stop behavior,
planner/guard parsing, and guarded executor routing are covered by tests.

Still later:

- JSON schema object enforcement in the provider request;
- invalid JSON retry with schema correction;
- richer action-result schemas for real OS execution.
