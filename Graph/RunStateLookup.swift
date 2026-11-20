import Foundation

/// Reads the run states of a few devices without reading the whole list of a script, which can hold thousands of devices
/// and comes back 50 at a time.
enum RunStateLookup {
    static let maxDevices = 10

    /// Asks Intune for only the run states of the given devices. Returns nil when Intune rejects the filter or ignores it
    /// (the first page then holds other devices), so the caller reads the full list instead.
    static func filtered(path: String, query: [URLQueryItem], deviceIDs: [String], client: GraphClient) async throws -> [GraphItem<RunState>]? {
        guard !deviceIDs.isEmpty, deviceIDs.count <= maxDevices,
              let ids = try? deviceIDs.map(DeviceStatusLoader.segment)
        else { return nil }
        let clause = ids.map { "managedDevice/id eq '\($0)'" }.joined(separator: " or ")
        let wanted = Set(ids)
        do {
            var page = try await client.page(RunState.self, url: client.url(path: path, query: query + [URLQueryItem(name: "$filter", value: clause)]))
            var items = page.items
            while true {
                guard items.allSatisfy({ wanted.contains($0.value.managedDevice?.id ?? "") }) else { return nil }
                guard let next = page.nextLink else { return items }
                page = try await client.page(RunState.self, url: next)
                items += page.items
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch GraphError.unauthorized {
            throw GraphError.unauthorized
        } catch {
            return nil
        }
    }
}
