import Foundation

public struct DeterministicPolicyEngine: Sendable {
    private let dangerousCommandFragments = [
        "rm ", "rm\t", "rm -", "/rm", "srm", "unlink", "shred",
        "sudo", "doas", "chmod", "chown", "chflags", "chgrp",
        "curl", "wget", "ftp ", "nc ", "ncat", "netcat", "telnet",
        "ssh ", "scp ", "sftp", "rsync", "socat",
        "dd ", "mkfs", "fdisk", "diskutil", "newfs", "apfs", "hdiutil",
        "shutdown", "reboot", "halt", "poweroff",
        "killall", "kill ", "pkill", "launchctl", "crontab",
        "defaults write", "nvram", "pmset", "systemsetup", "scutil",
        "tmutil", "mdutil", "dscl", "dsenableroot", "createhomedir",
        "passwd", "chsh", "chpass", "visudo", "spctl",
        "~/.ssh", ".ssh/", "id_rsa", "id_ed25519", "id_dsa", "id_ecdsa",
        "authorized_keys", "known_hosts", "keychain", "security ",
        ".env", ".aws", ".netrc", ".npmrc", ".pgpass", "credentials",
        "eval", "exec", "osascript", "/etc/", "/var/", "/private/",
        "mv ", "cp /", "> /", ">>", ">|",
        "$(", "`", "base64", "xxd", "openssl", "gpg ",
        "python -c", "python3 -c", "perl -e", "perl -n",
        "ruby -e", "node -e", "bash -c", "sh -c", "zsh -c", "awk ",
        "tee ", "xargs", "find ", "-exec", "-delete",
        "brew", "port install", "macports",
        "pip install", "pip3 install", "npm install", "npm i ",
        "yarn add", "pnpm add", "gem install", "cargo install",
        "go install", "apt ", "apt-get", "yum ", "dnf ", "snap install",
        "softwareupdate", "installer", "pkgutil", "open -a",
        "mail ", "sendmail", "smtp", "ifconfig", "iptables",
        "pfctl", "route ", "arp ", "history", "set -", "export ", "env "
    ]

    // Shell metacharacters that chain or substitute commands. If any appear
    // in an otherwise "allowlisted" command, we cannot reason about the full
    // command deterministically, so we must not auto-allow it. `\t` is included
    // because tabs separate tokens too and could otherwise hide arguments from
    // the space-delimited dangerous-fragment checks.
    private let commandChainingTokens = [
        ";", "&&", "||", "|", "&", "\n", "\r", "\t", "$(", "`",
        ">", "<", "{", "}", "(", ")", "!", "\\"
    ]

    private let riskyClickTerms = [
        "submit", "send", "delete", "remove", "confirm", "purchase", "buy",
        "pay", "order", "checkout", "install", "uninstall", "run", "execute",
        "allow", "accept", "agree", "grant", "authorize", "approve",
        "transfer", "withdraw", "publish", "deploy", "share", "post",
        "sign", "login", "log in", "log out", "logout", "reset", "erase",
        "format", "wipe", "trust", "enable", "disable",
        "download", "update", "upgrade", "unlock", "subscribe", "unsubscribe",
        "overwrite", "replace", "discard", "empty trash", "move to trash",
        "deactivate", "cancel subscription", "renew",
        "checkout now", "place order", "consent", "verify", "confirm payment"
    ]

    public init() {}

    public func classifyBatch(actions: [StructuredAction], context: AgentContext) -> PolicyDecision {
        guard actions.count == 1 else {
            return .init(classification: .block, reason: "Multi-action batches are blocked in v1.")
        }
        guard let action = actions.first else {
            return .init(classification: .block, reason: "No action was provided.")
        }
        return classify(action: action, context: context)
    }

    public func classify(action: StructuredAction, context: AgentContext) -> PolicyDecision {
        switch action.type {
        case .observe, .scroll, .wait, .finish, .askUser:
            return .init(classification: .allow, reason: "Low-risk action is allowed.")
        case .typeTextSensitive:
            return .init(classification: .block, reason: "Personal information and sensitive typing are blocked in v1.")
        case .runTerminalCommand:
            return classifyTerminalCommand(action.command)
        case .openURL:
            // Classify exactly the string the executor will open, which is
            // `text ?? targetText`. Reading only `targetText` here would let an
            // action carry a benign allowlisted `targetText` while opening a
            // malicious URL via `text`.
            return classifyURL(action.text ?? action.targetText, context: context)
        case .click, .doubleClick:
            return classifyClick(action)
        case .paste:
            return .init(classification: .askUser, reason: "Pasting requires user approval unless generated safe text is proven.")
        case .copy:
            return .init(classification: .askUser, reason: "Clipboard access requires user approval by default.")
        case .typeTextSafe, .pressKey, .switchApp:
            return action.riskLevel == .low
                ? .init(classification: .allow, reason: "Low-risk structured action is allowed.")
                : .init(classification: .askUser, reason: "Medium or high risk action requires approval.")
        }
    }

    private func classifyTerminalCommand(_ command: String?) -> PolicyDecision {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(classification: .block, reason: "Terminal command is missing.")
        }

        // Normalize: lowercase and collapse so evasion via case is impossible.
        let lowered = command.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)

        if dangerousCommandFragments.contains(where: { lowered.contains($0) }) {
            return .init(classification: .block, reason: "Deletion or dangerous terminal command is blocked.")
        }

        // Any shell chaining/substitution/redirection token means the command
        // may do more than its leading verb suggests. We refuse to auto-allow
        // such commands even if they start with an allowlisted prefix
        // (e.g. "cd /tmp && <anything>" or "cat f; <anything>").
        if commandChainingTokens.contains(where: { lowered.contains($0) }) {
            return .init(classification: .askUser, reason: "Chained or redirected terminal command requires approval.")
        }

        // Exact-match commands that take no arguments.
        let allowedExact: Set<String> = ["pwd", "ls", "git status", "git diff", "git log", "npm test", "npm run build"]
        if allowedExact.contains(trimmed) {
            return .init(classification: .allow, reason: "Workspace-safe terminal command is allowed by policy.")
        }

        // Prefix commands that take arguments. Require a separating space after
        // the verb so "cd " cannot be spoofed by "cder" and so we know the
        // remainder is an argument list (already proven free of chaining
        // tokens above).
        let allowedPrefixes = ["ls ", "cd ", "cat ", "git status ", "git diff ", "git log ", "npm test ", "npm run build "]
        if allowedPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .init(classification: .allow, reason: "Workspace-safe terminal command is allowed by policy.")
        }

        return .init(classification: .askUser, reason: "Unknown or medium-risk terminal command requires approval.")
    }

    private func classifyURL(_ rawURL: String, context: AgentContext) -> PolicyDecision {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Browsers treat backslashes as path separators, but URL/URLComponents
        // parse them inconsistently. A string like "https://allowed.com\\@evil.test"
        // can yield a benign host here while the executor's URL(string:) resolves
        // a different destination. Reject backslashes and embedded whitespace/
        // control characters rather than risk a parser-differential bypass.
        if trimmed.contains("\\") {
            return .init(classification: .block, reason: "URL contains a backslash and is blocked.")
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) {
            return .init(classification: .block, reason: "URL contains whitespace or control characters and is blocked.")
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return .init(classification: .block, reason: "Invalid URL is blocked.")
        }

        // Only http(s) is openable by the executor; everything else
        // (file:, javascript:, data:, ftp:, custom app schemes, ...) is blocked
        // so it cannot reach the OS even if the executor changes.
        guard scheme == "http" || scheme == "https" else {
            return .init(classification: .block, reason: "Non-web URL scheme is blocked.")
        }

        // `URLComponents.host` excludes any user-info component, so a spoof like
        // "https://allowed.com@evil.com" yields host "evil.com" (the real
        // destination), which correctly fails the allowlist below.
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return .init(classification: .block, reason: "URL has no host and is blocked.")
        }

        let normalizedAllowlist = Set(context.allowedDomains.map { $0.lowercased() })
        if normalizedAllowlist.contains(host) || normalizedAllowlist.contains(where: { host.hasSuffix("." + $0) }) {
            return .init(classification: .allow, reason: "Domain is in the task allowlist.")
        }

        return .init(classification: .askUser, reason: "Unapproved website requires user approval.")
    }

    private func classifyClick(_ action: StructuredAction) -> PolicyDecision {
        let target = action.targetText.lowercased()
        if riskyClickTerms.contains(where: { target.contains($0) }) {
            return .init(classification: .askUser, reason: "Risky click target requires approval.")
        }

        return action.riskLevel == .low
            ? .init(classification: .allow, reason: "Low-risk click is allowed.")
            : .init(classification: .askUser, reason: "Click risk level requires approval.")
    }
}
