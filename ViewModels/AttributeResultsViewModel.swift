import Foundation
import os

/// All device run states of one attribute, with search, run-state filter and sorting.
@MainActor
final class AttributeResultsViewModel: ObservableObject {
    let config: OSSourceConfig
    let script: ScriptSummary

    @Published private(set) var rows: [AttributeRow] = [] {
        didSet {
            runStates = Set(rows.map(\.runState).filter { !$0.isEmpty }).sorted()
            refilter()
        }
    }
    /// Rows after search and run-state filters, sorted. Recomputed only when one of those inputs changes.
    @Published private(set) var filteredRows: [AttributeRow] = [] { didSet { tableVersion &+= 1 } }
    /// Changes whenever the rows shown change. The table is rebuilt for each value instead of being compared row by row with the previous one, which freezes the window when thousands of rows change order.
    @Published private(set) var tableVersion = 0
    @Published private(set) var loadedCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = "" { didSet { refilter() } }
    @Published var runStateFilter: String? { didSet { refilter() } }
    @Published var sortOrder = [KeyPathComparator(\AttributeRow.device)] {
        // Table writes its sort order back after every update; acting only on a real change stops that from looping.
        didSet { if sortOrder != oldValue { refilter() } }
    }
    /// Serial and OS from the device inventory, because the expanded managedDevice can return them as null.
    @Published private(set) var inventory: [String: ManagedDevice] = [:]
    /// When the rows were read; shown in the header.
    @Published private(set) var loadedAt: Date?
    private var items: [GraphItem<RunState>] = []
    /// Results are shown from here when they were read recently. Tests pass none.
    private let cache: ResultsCache?
    /// Older results are shown at once and read again in the background.
    static let staleAfter: TimeInterval = 15 * 60
    /// The app passes `DeviceInventory.shared`; tests get their own, so nothing is cached between them.
    private let inventorySource: DeviceInventory

    init(config: OSSourceConfig, script: ScriptSummary, inventorySource: DeviceInventory = DeviceInventory(), cache: ResultsCache? = nil) {
        self.config = config
        self.script = script
        self.inventorySource = inventorySource
        self.cache = cache
    }

    /// Distinct run states for the filter menu, computed when the rows change rather than on every redraw.
    @Published private(set) var runStates: [String] = []

    /// Tables beyond this many rows are filtered and sorted off the main thread, so the window stays responsive.
    static let backgroundThreshold = 2000
    @Published private(set) var isFiltering = false
    private var filterTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "DeviceLookupForIntune", category: "table")

    private func refilter() {
        filterTask?.cancel()
        let rows = self.rows, search = searchText, state = runStateFilter, order = sortOrder
        guard rows.count >= Self.backgroundThreshold else {
            isFiltering = false
            filteredRows = RowSort.sorted(Self.filter(rows, search: search, runState: state), using: order)
            return
        }
        isFiltering = true
        filterTask = Task {
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) { RowSort.sorted(Self.filter(rows, search: search, runState: state), using: order) }.value
            guard !Task.isCancelled else { return }
            filteredRows = result
            isFiltering = false
            logger.info("filtered and sorted \(rows.count) rows in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")
        }
    }

    nonisolated static func filter(_ rows: [AttributeRow], search: String, runState: String?) -> [AttributeRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            (runState == nil || row.runState == runState)
                && (needle.isEmpty || row.searchText.localizedCaseInsensitiveContains(needle))
        }
    }

    /// `force` ignores what was read before (the Reload button).
    func load(client: GraphClient, force: Bool = false) async {
        let key = ResultsCache.key(config: config, script: script)
        let cached = force ? nil : cache?.entry(key)
        if let cached {
            items = cached.items
            inventory = cached.inventory
            rows = cached.rows
            loadedAt = cached.loadedAt
            loadedCount = cached.rows.count
            if Date().timeIntervalSince(cached.loadedAt) < Self.staleAfter {
                // A device search stores what it read without the device list: fill missing serials and OS from it now.
                if config.fillsInventory, inventory.isEmpty, rows.contains(where: { $0.serial.isEmpty || $0.deviceOS.isEmpty }),
                   let devices = try? await inventorySource.devices(client: client) {
                    fillInventory(devices)
                    cache?.store(key, CachedResults(items: items, rows: rows, inventory: inventory, loadedAt: cached.loadedAt))
                }
                return
            }
        }
        isLoading = true
        errorMessage = nil
        if cached == nil {
            rows = []
            items = []
            inventory = [:]
            loadedCount = 0
        }
        defer { isLoading = false }
        do {
            let progress: @MainActor (Int) -> Void = { [weak self] count in self?.loadedCount = count }
            // Status tables always need the device list, so it is read while they page in. Attribute tables read it only
            // when serial numbers or the OS are missing.
            let source = inventorySource
            let devicesRead = config.osName != nil ? Task { try await source.devices(client: client) } : nil
            if let report = config.report {
                items = try await report.items(id: script.id, client: client, progress: progress)
            } else {
                items = try await collectRunStates(client: client, progress: progress)
            }
            items = Self.unique(items)
            if let os = config.osName, let devicesRead {
                items = ofOS(os, items, devices: try await devicesRead.value, keepUnmatched: config.platform != nil)
            }
            rows = items.map { AttributeRow(item: $0, config: config) }
            if config.fillsInventory, rows.contains(where: { $0.serial.isEmpty || $0.deviceOS.isEmpty }) {
                let devices: [ManagedDevice]?
                if let devicesRead { devices = try? await devicesRead.value } else { devices = try? await source.devices(client: client) }
                if let devices { fillInventory(devices) }
            }
            loadedAt = Date()
            cache?.store(key, CachedResults(items: items, rows: rows, inventory: inventory, loadedAt: Date()))
        } catch is CancellationError {
            // Switched to another attribute or reloaded.
        } catch {
            errorMessage = config.message(for: error)
        }
    }

    /// Intune can return the same status more than once (paging overlaps, or a device reported twice); rows need unique ids.
    nonisolated static func unique(_ items: [GraphItem<RunState>]) -> [GraphItem<RunState>] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.value.id).inserted }
    }

    /// Intune pages these lists in small pages (often 50) whatever `$top` says; `collectBySkip` then reads several pages at once. If Intune rejects `$top`, the list is read without it.
    private func collectRunStates(client: GraphClient, progress: @MainActor @escaping (Int) -> Void) async throws -> [GraphItem<RunState>] {
        let path = config.runStatesPath(scriptID: script.id)
        do {
            return try await client.collectBySkip(RunState.self, path: path, query: config.runStatesQuery, progress: progress)
        } catch GraphError.http(400, _) where config.runStatesQuery.contains(where: { $0.name == "$top" }) {
            return try await client.collectBySkip(RunState.self, path: path, query: config.runStatesQuery.filter { $0.name != "$top" }, progress: progress)
        }
    }

    /// Keeps the statuses whose device name belongs to a device of the given OS in the Intune device list, and takes the
    /// serial number and OS version from that device, because the statuses carry only a name and a user.
    /// A list that already holds one platform (`config.platform`) keeps statuses whose device name is not in the device list.
    private func ofOS(_ os: String, _ items: [GraphItem<RunState>], devices: [ManagedDevice], keepUnmatched: Bool = false) -> [GraphItem<RunState>] {
        var byName: [String: ManagedDevice] = [:]
        for device in devices where device.operatingSystem?.caseInsensitiveCompare(os) == .orderedSame {
            if let name = device.deviceName?.lowercased(), byName[name] == nil { byName[name] = device }
        }
        return items.compactMap { item in
            guard let status = item.value.managedDevice, let known = byName[status.deviceName?.lowercased() ?? ""] else { return keepUnmatched ? item : nil }
            let device = ManagedDevice(
                id: status.id.isEmpty ? known.id : status.id, deviceName: status.deviceName, serialNumber: known.serialNumber,
                userPrincipalName: status.userPrincipalName, operatingSystem: known.operatingSystem,
                osVersion: status.osVersion ?? known.osVersion, azureADDeviceId: known.azureADDeviceId
            )
            return GraphItem(value: RunState(id: item.value.id, lastStateUpdateDateTime: item.value.lastStateUpdateDateTime, managedDevice: device), raw: item.raw)
        }
    }

    func operatingSystem(of row: AttributeRow) -> String {
        inventory[row.deviceID]?.operatingSystem ?? row.deviceOS
    }

    /// Keeps only the devices of these rows: the whole tenant's list would be copied into every cached table.
    private func fillInventory(_ devices: [ManagedDevice]) {
        let shown = Set(items.compactMap { $0.value.managedDevice?.id })
        inventory = Dictionary(devices.filter { shown.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serials = inventory.compactMapValues(\.serialNumber)
        rows = items.map { AttributeRow(item: $0, config: config, serials: serials) }
    }
}
