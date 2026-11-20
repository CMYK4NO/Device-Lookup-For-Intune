import Foundation

/// Compliance, configuration and managed apps of the selected devices. A part is read when its tab is opened,
/// one device at a time, and only once per selection.
@MainActor
final class DeviceStatusViewModel: ObservableObject {
    @Published private(set) var statuses: [String: DeviceStatus] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var generation = 0

    /// Starts loading, superseding a load still running.
    func begin(_ part: StatusPart, devices: [ManagedDevice], client: GraphClient) {
        task?.cancel()
        task = Task { await load(part, devices: devices, client: client) }
    }

    func load(_ part: StatusPart, devices: [ManagedDevice], client: GraphClient) async {
        generation += 1
        let mine = generation
        errorMessage = nil
        let pending = devices.filter { statuses[$0.id]?.loaded.contains(part) != true }
        isLoading = !pending.isEmpty
        defer { if generation == mine { isLoading = false } }
        for device in pending {
            do {
                let result = try await DeviceStatusLoader.load(part, for: device, client: client)
                guard generation == mine else { return }
                var status = statuses[device.id] ?? DeviceStatus()
                status.apply(part, from: result)
                statuses[device.id] = status
            } catch is CancellationError {
                return
            } catch {
                if generation == mine { errorMessage = error.localizedDescription }
                return
            }
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        generation += 1
        statuses = [:]
        errorMessage = nil
        isLoading = false
    }
}
