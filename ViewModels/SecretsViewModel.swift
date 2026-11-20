import Foundation
import os

/// Passwords and keys revealed for devices, kept in memory only until cleared.
@MainActor
final class SecretsViewModel: ObservableObject {
    @Published private(set) var reports: [String: SecretsReport] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var notices: [String: String] = [:]
    @Published private(set) var errorMessage: String?

    private var tasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "DeviceLookupForIntune", category: "secrets")

    func begin(_ device: ManagedDevice, client: GraphClient) {
        guard tasks[device.id] == nil else { return }
        tasks[device.id] = Task {
            await load(device, client: client)
            tasks[device.id] = nil
        }
    }

    func beginRotate(_ rotation: SecretRotation, device: ManagedDevice, client: GraphClient) {
        guard tasks[device.id] == nil else { return }
        tasks[device.id] = Task {
            await rotate(rotation, device: device, client: client)
            tasks[device.id] = nil
        }
    }

    func rotate(_ rotation: SecretRotation, device: ManagedDevice, client: GraphClient) async {
        errorMessage = nil
        loading.insert(device.id)
        defer { loading.remove(device.id) }
        do {
            try await rotation.perform(on: device, client: client)
            // What was revealed before is about to be replaced.
            reports[device.id] = nil
            notices[device.id] = "\(rotation.title): requested. The device applies it when it next checks in; reveal again afterwards."
            logger.info("Rotation requested for a device")
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(_ device: ManagedDevice, client: GraphClient) async {
        errorMessage = nil
        notices[device.id] = nil
        loading.insert(device.id)
        defer { loading.remove(device.id) }
        do {
            let report = try await DeviceSecretsLoader.load(for: device, client: client)
            // Cleared (selection changed or signed out) while the last request was finishing: the values must not come back.
            guard !Task.isCancelled else { return }
            reports[device.id] = report
            logger.info("Secrets requested for a device")
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops every revealed value and stops running requests.
    func clear() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        reports = [:]
        notices = [:]
        loading = []
        errorMessage = nil
    }
}
