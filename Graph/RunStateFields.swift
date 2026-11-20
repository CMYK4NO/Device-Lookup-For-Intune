import Foundation

/// The OS-specific fields of a run state, read from its raw JSON using the OS's config.
struct RunStateFields {
    let runState: String
    let value: String
    /// True when the configured value field was empty and `value` lists all populated fields instead.
    let valueIsFallback: Bool

    init(raw: String, config: OSSourceConfig) {
        let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        let rawState = object[config.runStateField] as? String ?? ""
        runState = config.runStateLabels[rawState] ?? rawState

        if let output = object[config.valueField] as? String,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = output
            valueIsFallback = false
            return
        }
        guard config.fallsBack else {
            value = ""
            valueIsFallback = false
            return
        }
        let populated = object.keys.sorted().compactMap { key -> String? in
            guard key != "id", key != "managedDevice", !key.hasPrefix("@") else { return nil }
            switch object[key] {
            case let text as String where !text.isEmpty: return "\(key): \(text)"
            case let number as NSNumber: return "\(key): \(number)"
            default: return nil
            }
        }
        value = populated.joined(separator: "; ")
        valueIsFallback = !populated.isEmpty
    }
}
