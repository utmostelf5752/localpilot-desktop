import Foundation

/// Dependency-free builder for the JSON Schema documents used to constrain
/// local-runtime structured output. Schemas are constructed as `[String: Any]`
/// dictionaries and serialized with `JSONSerialization` so we never hand-write
/// brittle JSON. All members are pure computed properties with no shared mutable
/// state, so they are `Sendable`-safe.
public enum StructuredOutputSchema {
    /// JSON Schema string for ONE `StructuredAction`. Property shape mirrors the
    /// `StructuredAction` decoder exactly.
    public static var action: String {
        serialize(actionSchemaObject)
    }

    /// JSON Schema string for the plan envelope: `{"actions":[ ...action ]}`.
    public static var plan: String {
        let object: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["actions"],
            "properties": [
                "actions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 6,
                    "items": actionSchemaObject
                ]
            ]
        ]
        return serialize(object)
    }

    /// JSON Schema string for a guard decision: `{decision, reason}`.
    public static var guardDecision: String {
        let object: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["decision", "reason"],
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": ["allow", "deny"]
                ],
                "reason": [
                    "type": "string"
                ]
            ]
        ]
        return serialize(object)
    }

    /// The action schema as a dictionary, reused inside the plan envelope.
    /// Includes the `actions` array so a top-level action may itself be a batch.
    private static var actionSchemaObject: [String: Any] {
        actionSchema(includeBatch: true)
    }

    /// A single action's schema. `includeBatch` adds the `move_cursor`/`batch`
    /// types and the `actions` sub-action array; sub-actions are emitted with
    /// `includeBatch: false` so a batch can never nest another batch (bounded
    /// recursion that small local models can follow).
    private static func actionSchema(includeBatch: Bool) -> [String: Any] {
        let actionTypes = includeBatch
            ? ActionType.allCases.map(\.rawValue)
            : ActionType.allCases.filter { $0 != .batch }.map(\.rawValue)

        var properties: [String: Any] = [
            "type": [
                "type": "string",
                "enum": actionTypes
            ],
            "target_kind": ["type": "string"],
            "target_text": ["type": "string"],
            "coordinates": [
                "type": ["array", "null"],
                "items": ["type": "number"]
            ],
            "target_element_id": ["type": ["integer", "null"]],
            "text": ["type": ["string", "null"]],
            "command": ["type": ["string", "null"]],
            "expected_result": ["type": "string"],
            "risk_level": [
                "type": "string",
                "enum": ["low", "medium", "high"]
            ],
            "reason": ["type": "string"]
        ]

        if includeBatch {
            properties["actions"] = [
                "type": ["array", "null"],
                "minItems": 1,
                "maxItems": 6,
                "items": actionSchema(includeBatch: false)
            ]
        }

        return [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "type",
                "target_kind",
                "target_text",
                "expected_result",
                "risk_level",
                "reason"
            ],
            "properties": properties
        ]
    }

    private static func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
