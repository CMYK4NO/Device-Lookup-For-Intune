import Foundation

/// The Intune device list (id, name, serial, OS), shared by every table that needs serials or the OS of a device.
/// In a large tenant it is several requests, so it must not be repeated per attribute. It is read again after
/// `maxAge`, so devices enrolled while the app is open appear in the tables.
actor DeviceInventory {
    static let shared = DeviceInventory()
    static let maxAge: TimeInterval = 30 * 60

    private var loading: Task<[ManagedDevice], Error>?
    private var startedAt = Date.distantPast

    func devices(client: GraphClient) async throws -> [ManagedDevice] {
        if let loading, Date().timeIntervalSince(startedAt) < Self.maxAge { return try await loading.value }
        startedAt = Date()
        let task = Task {
            try await client.collect(
                ManagedDevice.self,
                path: "/deviceManagement/managedDevices",
                query: [URLQueryItem(name: "$select", value: "id,deviceName,serialNumber,operatingSystem,osVersion"), URLQueryItem(name: "$top", value: "999")]
            ).map(\.value)
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil // A failed or cancelled read is retried next time.
            throw error
        }
    }

    func reset() {
        loading = nil
    }
}
