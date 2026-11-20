import Foundation

/// One password or recovery key of a device. Held in memory only while shown.
struct DeviceSecret: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let value: String
    let date: Date?
    /// The action that replaces this value.
    let rotation: SecretRotation
}

struct SecretsReport: Equatable {
    var secrets: [DeviceSecret] = []
    /// Why a source gave nothing (not stored, no permission, …).
    var notes: [String] = []
}

/// Reads the FileVault key and LAPS password of macOS devices and the LAPS password and BitLocker keys of Windows devices.
/// Nothing here logs or keeps a value; callers own the result.
enum DeviceSecretsLoader {
    private struct StringValue: Decodable { let value: String? }

    private struct LAPSInfo: Decodable {
        struct Credential: Decodable {
            let accountName: String?
            let backupDateTime: String?
            let passwordBase64: String?
        }
        let credentials: [Credential]?
    }

    private struct BitLockerKey: Decodable {
        let id: String
        let createdDateTime: String?
        let volumeType: String?
        let key: String?
    }

    /// Intune's macOS LAPS account (macOSManagedDeviceLocalAdminAccountDetail): the password in plain text and its last rotation.
    /// Other field names are still accepted in case the beta shape changes.
    private struct MacAdminAccounts: Decodable {
        struct Account: Decodable {
            let accountName: String?
            let userName: String?
            let adminAccountPassword: String?
            let passwordLastRotatedDateTime: String?
            let password: String?
            let passwordBase64: String?
            let lastPasswordRotationDateTime: String?
            let lastModifiedDateTime: String?
        }
        let accounts: [Account]

        private enum Keys: String, CodingKey { case value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let list = try? container.decode([Account].self, forKey: .value) {
                accounts = list
            } else if let single = try? container.decode(Account.self, forKey: .value) {
                accounts = [single]
            } else {
                accounts = [try Account(from: decoder)]
            }
        }
    }

    private enum Source: String {
        case fileVault = "FileVault recovery key"
        case macOSLAPS = "macOS local administrator password"
        case laps = "Local administrator password"
        case bitLocker = "BitLocker recovery key"
    }

    /// A source that fails with 404 or a Graph error becomes a note; sign-in, consent and cancellation errors abort the load.
    static func load(for device: ManagedDevice, client: GraphClient) async throws -> SecretsReport {
        var report = SecretsReport()
        let sources: [Source]
        switch device.operatingSystem?.lowercased() {
        case "macos": sources = [.fileVault, .macOSLAPS]
        case "windows": sources = [.laps, .bitLocker]
        default: return report
        }
        for source in sources {
            do {
                switch source {
                case .fileVault: report.secrets += try await fileVault(device, client)
                case .macOSLAPS:
                    let found = try await macOSLAPS(device, client)
                    if found.isEmpty { report.notes.append("\(source.rawValue): the device returned no password. It needs a LAPS-enabled ADE enrollment profile.") }
                    report.secrets += found
                case .laps: report.secrets += try await laps(device, client)
                case .bitLocker: report.secrets += try await bitLocker(device, client)
                }
            } catch GraphError.http(status: 404, _) {
                report.notes.append("\(source.rawValue): none is stored for this device.")
            } catch let error as GraphError where error != .unauthorized {
                report.notes.append("\(source.rawValue): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Ids go into URLs and filters, so only GUIDs are accepted.
    static func guid(_ text: String?) throws -> String {
        guard let text, let id = UUID(uuidString: text) else { throw GraphError.invalidRequest }
        return id.uuidString.lowercased()
    }

    private static func fileVault(_ device: ManagedDevice, _ client: GraphClient) async throws -> [DeviceSecret] {
        let url = try client.url(path: "/deviceManagement/managedDevices/\(try guid(device.id))/getFileVaultKey")
        guard let key = try await client.get(StringValue.self, url: url).value, !key.isEmpty else { return [] }
        return [DeviceSecret(id: "filevault", title: Source.fileVault.rawValue, detail: nil, value: key, date: nil, rotation: .fileVault)]
    }

    private static func macOSLAPS(_ device: ManagedDevice, _ client: GraphClient) async throws -> [DeviceSecret] {
        let url = try client.url(path: "/deviceManagement/managedDevices/\(try guid(device.id))/retrieveMacOSManagedDeviceLocalAdminAccountDetail")
        let accounts = try await client.get(MacAdminAccounts.self, url: url).accounts
        return accounts.enumerated().compactMap { index, account in
            let password = account.adminAccountPassword ?? account.password ?? account.passwordBase64.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
            guard let password, !password.isEmpty else { return nil }
            return DeviceSecret(
                id: "macos-laps-\(index)",
                title: Source.macOSLAPS.rawValue,
                detail: account.accountName ?? account.userName,
                value: password,
                date: GraphDate.parse(account.passwordLastRotatedDateTime ?? account.lastPasswordRotationDateTime ?? account.lastModifiedDateTime),
                rotation: .laps
            )
        }
    }

    private static func laps(_ device: ManagedDevice, _ client: GraphClient) async throws -> [DeviceSecret] {
        let url = try client.url(
            path: "/directory/deviceLocalCredentials/\(try guid(device.azureADDeviceId))",
            query: [URLQueryItem(name: "$select", value: "credentials")]
        )
        let credentials = try await client.get(LAPSInfo.self, url: url).credentials ?? []
        return credentials.enumerated().compactMap { index, credential in
            guard let encoded = credential.passwordBase64, let data = Data(base64Encoded: encoded) else { return nil }
            return DeviceSecret(
                id: "laps-\(index)",
                title: Source.laps.rawValue,
                detail: credential.accountName,
                value: String(decoding: data, as: UTF8.self),
                date: GraphDate.parse(credential.backupDateTime),
                rotation: .laps
            )
        }
    }

    private static func bitLocker(_ device: ManagedDevice, _ client: GraphClient) async throws -> [DeviceSecret] {
        let entraID = try guid(device.azureADDeviceId)
        let keys = try await client.collect(
            BitLockerKey.self,
            path: "/informationProtection/bitlocker/recoveryKeys",
            query: [URLQueryItem(name: "$filter", value: "deviceId eq '\(entraID)'")]
        )
        var secrets: [DeviceSecret] = []
        for item in keys {
            let url = try client.url(
                path: "/informationProtection/bitlocker/recoveryKeys/\(try guid(item.value.id))",
                query: [URLQueryItem(name: "$select", value: "key")]
            )
            guard let key = try await client.get(BitLockerKey.self, url: url).key, !key.isEmpty else { continue }
            secrets.append(DeviceSecret(
                id: "bitlocker-\(item.value.id)",
                title: Source.bitLocker.rawValue,
                detail: volumeName(item.value.volumeType),
                value: key,
                date: GraphDate.parse(item.value.createdDateTime),
                rotation: .bitLocker
            ))
        }
        return secrets.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func volumeName(_ type: String?) -> String? {
        switch type {
        case "operatingSystemVolume": return "Operating system drive"
        case "fixedDataVolume": return "Fixed data drive"
        case "removableDataVolume": return "Removable drive"
        default: return type
        }
    }
}
