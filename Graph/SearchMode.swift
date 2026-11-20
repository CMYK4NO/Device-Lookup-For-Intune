import Foundation

/// What the user types to find devices: a user's UPN, or a device name / serial number.
enum SearchMode: Equatable {
    case upn
    case device

    var prompt: String {
        switch self {
        case .upn: return "user@company.com"
        case .device: return "Device name or serial number"
        }
    }

    /// Shown before the first search.
    var startMessage: String {
        switch self {
        case .upn: return "Enter a user principal name."
        case .device: return "Enter a device name."
        }
    }

    var invalidMessage: String {
        switch self {
        case .upn: return "Enter a valid user principal name, for example name@company.com."
        case .device: return "Enter part of a device name or a serial number."
        }
    }

    /// The trimmed search term, or nil if it cannot be used.
    func validated(_ input: String) -> String? {
        switch self {
        case .upn:
            return UPNQuery.validated(input)
        case .device:
            let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let forbidden = CharacterSet.controlCharacters
            guard !term.isEmpty, term.count <= 100, term.rangeOfCharacter(from: forbidden) == nil else { return nil }
            return term
        }
    }

    /// The managedDevices queries whose combined results answer the search. A device search matches the name or the serial number.
    func devicesQueries(for term: String) -> [[URLQueryItem]] {
        switch self {
        case .upn:
            return [UPNQuery.devicesQuery(upn: term)]
        case .device:
            return ["deviceName", "serialNumber"].map { field in
                [
                    URLQueryItem(name: "$filter", value: "contains(\(field),'\(UPNQuery.escape(term))')"),
                    URLQueryItem(name: "$select", value: UPNQuery.deviceFields),
                ]
            }
        }
    }
}
