# Context Compaction

LocalPilot needs compaction because screenshots, OCR text, accessibility trees, browser metadata, and action logs can quickly fill a local model context window.

## Required Layering

Never summarize these layers away:

1. Immutable safety policy.
2. Original user task.
3. Permission scope.
4. User approvals and denials.
5. Current structured state.

Compacted or rolling layers:

6. Compacted old history.
7. Recent raw history.
8. Latest observation.
9. Proposed action.

## 80/20 Rule

When estimated context usage reaches 80 percent of the configured model context window:

- summarize the oldest 80 percent of history;
- keep the newest 20 percent raw;
- inject original task directly;
- inject immutable safety policy directly;
- inject current permissions directly;
- inject denied actions directly;
- inject user approvals directly;
- inject current structured state directly.

## Source Of Truth

Natural-language summaries are not authoritative. A structured state object remains the source of truth.

Required files for later milestones:

- `state.json`
- `recent_steps.jsonl`
- `compacted_history.md`
- `approvals.jsonl`
- `logs.jsonl`

## Implemented Now

`ContextCompactor` currently exposes the 80 percent threshold calculation and configuration. Persistence, summarization, token estimation, and raw-history splitting are stubbed for Milestone 7.
