# Safety Policy

The deterministic policy engine is the primary safety boundary. The guard model is extra review, not authority. LocalPilot fails closed when context is insufficient.

## Implemented Now

The initial `DeterministicPolicyEngine` enforces:

- no multi-action batches;
- deletion and dangerous terminal command fragments are blocked;
- sensitive typing is blocked in v1;
- unapproved domains require user approval;
- clipboard copy/paste requires approval by default;
- low-risk observe, scroll, wait, finish, and ask-user actions are allowed;
- risky click targets such as submit, send, delete, purchase, install, run, allow, and grant access require approval.

The app now also exposes a native approval review sheet for `ask_user` decisions. Approval is "Allow once" or "Deny"; there are no broad approvals.

## Non-Negotiable v1 Rules

- No deletion features.
- No personal information autofill.
- No unapproved websites.
- No unrestricted terminal commands.
- No clipboard reading by default.
- No multi-action batches.
- One structured action at a time.
- Stop and Pause are independent from the model.
- Model sessions are closed after Stop, blocked tasks, and completed tasks when `Unload models after each run` is enabled.
- Mouse, double-click, keyboard, scroll, copy, approved paste, URL open,
  terminal command, and app-switch execution remain behind the app-owned
  executor and the dry-run setting. The model can only request structured
  actions; it never receives direct CGEvent, clipboard, NSWorkspace, or shell
  access.

## Terminal Policy

Allowed without approval only in approved workspace contexts:

- `pwd`
- `ls`
- `cd` within approved workspace
- `cat` inside approved workspace
- `git status`
- `git diff`
- `git log`
- `npm test`
- `npm run build`

Requires approval:

- installs;
- commits and pushes;
- file creation or config edits;
- network commands;
- unknown scripts;
- commands outside the approved workspace.

Blocked:

- deletion such as `rm` and `rm -rf`;
- `sudo`;
- recursive ownership or permission changes;
- `curl | sh` and `wget | sh`;
- disk erase or shutdown commands;
- reading SSH keys, Keychain, browser profiles, or `.env` files without explicit future approval.

## Personal Information

LocalPilot v1 must not enter names, addresses, phone numbers, emails, passwords, payment information, government IDs, health information, private account details, credentials, tokens, API keys, or private messages. If encountered, pause or ask the user to handle it manually.
