import Foundation

/// Intune remote actions that replace a device's password or recovery key.
enum SecretRotation: Equatable {
    case fileVault
    case laps
    case bitLocker

    var title: String {
        switch self {
        case .fileVault: return "Rotate FileVault recovery key"
        case .laps: return "Rotate local administrator password"
        case .bitLocker: return "Rotate BitLocker recovery keys"
        }
    }

    var consequence: String {
        switch self {
        case .fileVault: return "A new personal recovery key is generated. The current one stops being valid."
        case .laps: return "A new local administrator password is generated. The current one stops working once the device applies it."
        case .bitLocker: return "New BitLocker recovery keys are generated. The current ones stop being valid."
        }
    }

    var action: String {
        switch self {
        case .fileVault: return "rotateFileVaultKey"
        case .laps: return "rotateLocalAdminPassword"
        case .bitLocker: return "rotateBitLockerKeys"
        }
    }

    /// Sends the request. The device applies it when it next checks in, so success only means "requested".
    func perform(on device: ManagedDevice, client: GraphClient) async throws {
        let id = try DeviceSecretsLoader.guid(device.id)
        try await client.post(url: try client.url(path: "/deviceManagement/managedDevices/\(id)/\(action)"))
    }
}
