import Foundation

// Reasoning-model output handling.
//
// Reasoning models (qwen3, deepseek-r1, gpt-oss, ...) emit chain-of-thought
// before their answer. Runtimes surface it two ways:
//   1. A separate response field — `reasoning_content` (LM Studio / OpenAI),
//      `reasoning`, or `thinking` (Ollama). Our providers fold that into the
//      returned string as a <think>...</think> prefix via `lpEmbedReasoning`.
//   2. Inline <think>...</think> / <thinking>...</thinking> in the content.
// `lpSplitReasoning` peels both back off so the JSON decoders never choke on the
// reasoning and the chat UI can show it on its own. This is the local-model
// equivalent of parsing OpenAI Harmony channels: those models aren't Harmony, so
// we normalize whatever the runtime gives us instead of hand-rolling that format.

/// Wraps `reasoning` as a <think> prefix on `content` so one downstream splitter
/// handles server-separated and inline reasoning identically. No-op when there
/// is no reasoning or the content already carries a think tag.
func lpEmbedReasoning(content: String, reasoning: String?) -> String {
    guard let reasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
          !reasoning.isEmpty,
          content.range(of: "<think", options: .caseInsensitive) == nil else {
        return content
    }
    return "<think>\(reasoning)</think>\n\(content)"
}

/// Splits raw model output into (content, reasoning). `reasoning` is nil when the
/// model emitted none.
func lpSplitReasoning(_ raw: String) -> (content: String, reasoning: String?) {
    var reasoning: [String] = []
    var content = raw

    // Paired <think>...</think> and <thinking>...</thinking>, case-insensitive,
    // spanning newlines.
    for tag in ["think", "thinking"] {
        content = lpReplaceMatches("<\(tag)>([\\s\\S]*?)</\(tag)>", in: content) { inner in
            reasoning.append(inner)
            return ""
        }
    }

    // Lone trailing opener (truncated thought, no closer): everything after the
    // last opener is reasoning. ponytail: covers the common truncation case, not
    // nested channels — add a real parser if a model starts nesting them.
    if let opener = content.range(of: "<think>", options: [.caseInsensitive, .backwards])
        ?? content.range(of: "<thinking>", options: [.caseInsensitive, .backwards]) {
        reasoning.append(String(content[opener.upperBound...]))
        content = String(content[..<opener.lowerBound])
    }

    content = lpStripCodeFences(content).trimmingCharacters(in: .whitespacesAndNewlines)
    let joined = reasoning.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (content, joined.isEmpty ? nil : joined)
}

/// Best-effort extraction of the JSON object/array from cleaned model text that
/// may still carry stray prose. Returns the input untouched when no braces are
/// found, so the caller's decode surfaces the real error.
/// ponytail: first-brace-to-last-brace; upgrade to a balanced scan only if models
/// start emitting trailing JSON-ish prose.
func lpExtractJSONPayload(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
       let last = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }),
       first < last {
        return String(trimmed[first...last])
    }
    return trimmed
}

private func lpStripCodeFences(_ s: String) -> String {
    lpReplaceMatches("```[a-zA-Z0-9]*", in: s) { _ in "" }
}

/// Replaces regex matches, passing capture group 1 (or the whole match when there
/// is no group) to `transform`. Returns the original text if the pattern fails to
/// compile.
private func lpReplaceMatches(_ pattern: String, in text: String, _ transform: (String) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
        return text
    }
    let ns = text as NSString
    var result = ""
    var lastEnd = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
        let groupRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        let inner = groupRange.location == NSNotFound ? "" : ns.substring(with: groupRange)
        result += transform(inner)
        lastEnd = match.range.location + match.range.length
    }
    result += ns.substring(from: lastEnd)
    return result
}
