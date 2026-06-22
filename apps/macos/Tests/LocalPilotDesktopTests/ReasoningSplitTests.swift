import Foundation
import Testing
@testable import LocalPilotDesktop

struct ReasoningSplitTests {
    @Test
    func stripsInlineThinkBlock() {
        let (content, reasoning) = lpSplitReasoning("<think>plan it</think>{\"a\":1}")
        #expect(content == "{\"a\":1}")
        #expect(reasoning == "plan it")
    }

    @Test
    func plainJSONHasNoReasoning() {
        let (content, reasoning) = lpSplitReasoning("{\"a\":1}")
        #expect(content == "{\"a\":1}")
        #expect(reasoning == nil)
    }

    @Test
    func stripsMarkdownCodeFences() {
        let (content, _) = lpSplitReasoning("```json\n{\"a\":1}\n```")
        #expect(content == "{\"a\":1}")
    }

    @Test
    func thinkingTagVariantAndProseAroundJSON() {
        let (content, reasoning) = lpSplitReasoning("<thinking>hmm</thinking>ok {\"a\":1} done")
        #expect(reasoning == "hmm")
        #expect(lpExtractJSONPayload(content) == "{\"a\":1}")
    }

    @Test
    func embedThenSplitRoundTrips() {
        // Mirrors the provider path: server-separated reasoning is embedded as a
        // <think> prefix, then split back out downstream.
        let embedded = lpEmbedReasoning(content: "{\"a\":1}", reasoning: "because")
        let (content, reasoning) = lpSplitReasoning(embedded)
        #expect(content == "{\"a\":1}")
        #expect(reasoning == "because")
    }

    @Test
    func embedIsNoOpWhenContentAlreadyHasThink() {
        let already = "<think>x</think>{\"a\":1}"
        #expect(lpEmbedReasoning(content: already, reasoning: "y") == already)
    }
}
