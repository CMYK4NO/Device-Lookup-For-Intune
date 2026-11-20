import Foundation

/// Building blocks for looking up a user's devices by UPN.
enum UPNQuery {
    static let devicesPath = "/deviceManagement/managedDevices"
    static let deviceFields = "id,deviceName,serialNumber,operatingSystem,osVersion,azureADDeviceId,userId,lastSyncDateTime,enrolledDateTime"

    /// The trimmed UPN, or nil if it is not shaped like `name@domain.tld`.
    static func validated(_ input: String) -> String? {
        let upn = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = upn.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              upn.rangeOfCharacter(from: forbidden) == nil
        else { return nil }
        return upn
    }

    /// OData string literals escape a single quote by doubling it.
    static func escape(_ upn: String) -> String {
        upn.replacingOccurrences(of: "'", with: "''")
    }

    static func devicesQuery(upn: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "$filter", value: "userPrincipalName eq '\(escape(upn))'"),
            URLQueryItem(name: "$select", value: deviceFields),
        ]
    }
}
