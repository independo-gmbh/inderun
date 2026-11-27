import Foundation

/// Checks a raw, not yet decoded `TaskRequest` JSON object for what `Codable` would lose (ADR 025).
///
/// The generated `Codable` types drop unknown keys, so a misspelled control such as
/// `speech.controls.speakingrate` would decode as no control at all, and a misspelled required
/// control would vanish before any validation sees it. A JSON entry point that decodes a request
/// it did not build itself (a bridge, a message channel) runs this on the parsed JSON first and
/// refuses the request when it returns any issue. It is a targeted check, not a schema engine:
/// it covers the schema version and the closed control objects (`speech.controls`,
/// `delivery.playback` and the requested numbers inside them), which are the only places where
/// silent loss changes what executes. Everything else is checked after decoding by the engine's
/// request validation, as for typed callers.
public enum RawTaskRequestValidation {
    /// The issues found in `json`, the result of `JSONSerialization.jsonObject(with:)`. Empty
    /// when nothing that decoding would lose is wrong.
    public static func issues(_ json: Any) -> [String] {
        guard let request = json as? [String: Any] else {
            return ["request must be a JSON object."]
        }
        var issues: [String] = []
        if request["schemaVersion"] as? String != SchemaVersion.the11.rawValue {
            issues.append("schemaVersion must be '\(SchemaVersion.the11.rawValue)'.")
        }
        if let speech = request["speech"] as? [String: Any], let controls = speech["controls"] {
            issues += closedObject(controls, at: "speech.controls", keys: ["speakingRate", "pitch"])
        }
        if let delivery = request["delivery"] as? [String: Any], let playback = delivery["playback"] {
            issues += closedObject(playback, at: "delivery.playback", keys: ["volume"])
        }
        return issues
    }

    private static func closedObject(_ value: Any, at path: String, keys: Set<String>) -> [String] {
        guard let object = value as? [String: Any] else {
            return ["\(path) must be an object."]
        }
        var issues = object.keys.filter { !keys.contains($0) }.sorted().map { "\(path).\($0) is not a known control." }
        for key in keys.sorted() {
            if let requested = object[key] {
                issues += requestedNumber(requested, at: "\(path).\(key)")
            }
        }
        return issues
    }

    private static func requestedNumber(_ value: Any, at path: String) -> [String] {
        guard let object = value as? [String: Any] else {
            return ["\(path) must be an object."]
        }
        var issues = object.keys.filter { $0 != "value" && $0 != "requirement" }.sorted()
            .map { "\(path).\($0) is not allowed." }
        if let number = object["value"] as? NSNumber, !isBoolean(number), number.doubleValue.isFinite {
            // The domain (greater than 0, or 0 to 1) is checked after decoding.
        } else {
            issues.append("\(path).value must be a finite number.")
        }
        if let requirement = object["requirement"],
           (requirement as? String).flatMap(RequirementLevel.init(rawValue:)) == nil {
            issues.append("\(path).requirement must be 'preferred' or 'required'.")
        }
        return issues
    }

    /// `JSONSerialization` returns JSON booleans as `NSNumber` too.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
