import Foundation

/// Finds devices (by user UPN or by device name / serial), then reads chosen custom attributes for the selected ones.
@MainActor
final class DeviceSearchViewModel: ObservableObject {
    /// One attribute (script) the user can choose to read.
    struct AttributeChoice: Identifiable, Sendable {
        let config: OSSourceConfig
        let script: ScriptSummary
        var id: String { "\(config.id)/\(script.id)" }
    }

    private struct JobOutcome: Sendable {
        let key: String
        var rows: [SearchResultRow] = []
        var warning: String?
        /// The script's whole run-state list, when it had to be read, so the next search and the attribute's table reuse it.
        var fullRead: CachedResults?
    }

    static let maxInFlight = 2

    let mode: SearchMode
    let secrets = SecretsViewModel()
    let status = DeviceStatusViewModel()
    /// Run states read in the last minutes by the attribute tables, the warm-up or an earlier search. The app passes the
    /// shared cache; tests pass none.
    private let cache: ResultsCache?

    @Published var query = ""
    @Published var osFilter: String? {
        // Hidden devices leave the selection, but results already read stay: the filter then only changes what is shown.
        didSet {
            isNarrowing = true
            selection = selection.intersection(visibleDevices.map(\.id))
            isNarrowing = false
        }
    }
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var hasRead = false
    @Published private(set) var devices: [ManagedDevice] = []
    @Published var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue, !isNarrowing else { return }
            secrets.clear()
            status.clear()
            clearAttributes()
        }
    }
    @Published private(set) var choices: [AttributeChoice] = []
    @Published private(set) var chosenAttributes: Set<String> = []
    @Published private(set) var isLoadingAttributes = false
    @Published private(set) var rows: [SearchResultRow] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var completedJobs = 0
    @Published private(set) var totalJobs = 0
    @Published private(set) var infoMessage: String?
    @Published private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var isNarrowing = false
    private var generation = 0
    private var readDevices: [ManagedDevice] = []

    init(mode: SearchMode = .upn, cache: ResultsCache? = nil) {
        self.mode = mode
        self.cache = cache
    }

    // MARK: Derived state

    /// The devices matching the OS filter.
    var visibleDevices: [ManagedDevice] {
        guard let osFilter else { return devices }
        return devices.filter { Self.config(for: $0)?.id == osFilter }
    }

    /// The selected devices that pass the OS filter.
    var selectedDevices: [ManagedDevice] {
        visibleDevices.filter { selection.contains($0.id) }
    }

    /// Selected devices that can have passwords or keys (macOS and Windows).
    var secretDevices: [ManagedDevice] {
        visibleDevices.filter {
            selection.contains($0.id) && ["macos", "windows"].contains($0.operatingSystem?.lowercased() ?? "")
        }
    }

    var visibleRows: [SearchResultRow] {
        guard let osFilter else { return rows }
        return rows.filter { $0.osID == osFilter }
    }

    /// Why the result list is empty although devices were found, if it is.
    var emptyResultsMessage: String? {
        guard hasRead, !isSearching, errorMessage == nil, infoMessage == nil, visibleRows.isEmpty else {
            return nil
        }
        guard let osFilter else { return "The selected devices have not reported any custom attribute results." }
        let name = OSSourceConfig.all.first { $0.id == osFilter }?.name ?? osFilter
        let hasDevicesOfOS = readDevices.contains { Self.config(for: $0)?.id == osFilter }
        return hasDevicesOfOS ? "No \(name) results for the selected devices." : "None of the selected devices is a \(name) device."
    }

    var statusText: String? {
        if isSearching {
            if isLoadingAttributes { return "Loading attributes…" }
            return hasRead ? "Reading attributes… \(completedJobs) of \(totalJobs)" : "Finding devices…"
        }
        guard hasSearched, !devices.isEmpty else { return nil }
        guard hasRead else { return "\(devices.count) device(s) found." }
        return "\(readDevices.count) device(s) read, \(visibleRows.count) result(s)"
    }

    // MARK: Actions

    func beginSearch(client: GraphClient) {
        launch { await self.search(client: client) }
    }

    func beginLoadAttributes(client: GraphClient) {
        launch { await self.loadAttributes(client: client) }
    }

    func beginRead(client: GraphClient) {
        launch { await self.readAttributes(client: client) }
    }

    /// Starts `work`, superseding any search still running.
    private func launch(_ work: @escaping @MainActor () async -> Void) {
        searchTask?.cancel()
        generation += 1
        let mine = generation
        searchTask = Task {
            await work()
            if generation == mine { searchTask = nil }
        }
    }

    func cancel() {
        searchTask?.cancel()
    }

    func reset() {
        searchTask?.cancel()
        query = ""
        osFilter = nil
        hasSearched = false
        clearResults()
    }

    func search(client: GraphClient) async {
        clearResults()
        guard let term = mode.validated(query) else {
            errorMessage = mode.invalidMessage
            return
        }
        hasSearched = true
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await findDevices(term, client: client)
            // iOS, Android and other platforms have no custom attributes, so they are left out.
            devices = found.filter { Self.config(for: $0) != nil }
            guard !devices.isEmpty else {
                infoMessage = found.isEmpty ? "No devices found for \(term)." : "No macOS, Windows or Linux devices found for \(term)."
                return
            }
        } catch is CancellationError {
            infoMessage = "Search cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs the lookup queries of the mode and merges their devices. One failing query is a warning if another succeeded.
    private func findDevices(_ term: String, client: GraphClient) async throws -> [ManagedDevice] {
        let queries = mode.devicesQueries(for: term)
        var found: [ManagedDevice] = []
        var failures: [Error] = []
        for query in queries {
            do {
                found += try await client.collect(ManagedDevice.self, path: UPNQuery.devicesPath, query: query).map(\.value)
            } catch where Self.isFatal(error) {
                throw error
            } catch {
                failures.append(error)
            }
        }
        if failures.count == queries.count, let first = failures.first { throw first }
        warnings += failures.map(\.localizedDescription)
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// Step 2: lists the attributes of the OS of each selected device, as soon as the selection changes. Nothing is read yet.
    func loadAttributes(client: GraphClient) async {
        let chosen = devices.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let selected = selection
        clearAttributes()
        readDevices = chosen
        let configs = OSSourceConfig.all.filter { config in chosen.contains { Self.config(for: $0) == config } }
        isSearching = true
        isLoadingAttributes = true
        defer {
            isSearching = false
            isLoadingAttributes = false
        }
        do {
            let found = try await attributeChoices(client: client, configs: configs)
            guard selection == selected else { return }
            choices = found
            if choices.isEmpty && warnings.isEmpty { infoMessage = "No custom attributes are defined for these devices' OS." }
        } catch is CancellationError {
            // A changed selection supersedes this load silently; only a Cancel keeps the same selection.
            if selection == selected { infoMessage = "Search cancelled." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Step 3: reads only the chosen attributes, for the selected devices.
    func readAttributes(client: GraphClient) async {
        let jobs = choices.filter { chosenAttributes.contains($0.id) }
        guard !jobs.isEmpty else { return }
        rows = []
        warnings = []
        completedJobs = 0
        totalJobs = jobs.count
        infoMessage = nil
        errorMessage = nil
        hasRead = true
        isSearching = true
        defer { isSearching = false }
        do {
            let byID = Dictionary(readDevices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let outcomes = try await run(jobs, client: client, devices: byID, known: recentRunStates(of: jobs))
            rows = outcomes.flatMap(\.rows).sorted(by: Self.rowOrder)
            warnings += outcomes.compactMap(\.warning)
            for outcome in outcomes {
                if let read = outcome.fullRead { cache?.store(outcome.key, read) }
            }
        } catch is CancellationError {
            infoMessage = "Search cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleAttribute(_ id: String) {
        if chosenAttributes.contains(id) { chosenAttributes.remove(id) } else { chosenAttributes.insert(id) }
    }

    func selectAllAttributes() {
        chosenAttributes = Set(choices.map(\.id))
    }

    func clearAttributeSelection() {
        chosenAttributes = []
    }

    // MARK: Search steps

    private static func config(for device: ManagedDevice) -> OSSourceConfig? {
        OSSourceConfig.all.first { $0.name.caseInsensitiveCompare(device.operatingSystem ?? "") == .orderedSame }
    }

    private func clearResults() {
        secrets.clear()
        status.clear()
        devices = []
        selection = []
        clearAttributes()
    }

    private func clearAttributes() {
        choices = []
        chosenAttributes = []
        readDevices = []
        hasRead = false
        rows = []
        warnings = []
        completedJobs = 0
        totalJobs = 0
        infoMessage = nil
        errorMessage = nil
    }

    private func attributeChoices(client: GraphClient, configs: [OSSourceConfig]) async throws -> [AttributeChoice] {
        var found: [AttributeChoice] = []
        for config in configs {
            do {
                let scripts = try await client.collect(ScriptSummary.self, path: config.listPath, query: config.listQuery)
                let sorted = scripts.map(\.value).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                found += sorted.map { AttributeChoice(config: config, script: $0) }
            } catch where Self.isFatal(error) {
                throw error
            } catch {
                warnings.append("\(config.name): \(error.localizedDescription)")
            }
        }
        return found
    }

    /// Whole run-state lists of these scripts read less than `AttributeResultsViewModel.staleAfter` ago, by job id.
    private func recentRunStates(of jobs: [AttributeChoice]) -> [String: [GraphItem<RunState>]] {
        guard let cache else { return [:] }
        var known: [String: [GraphItem<RunState>]] = [:]
        for job in jobs {
            if let entry = cache.entry(ResultsCache.key(config: job.config, script: job.script)),
               Date().timeIntervalSince(entry.loadedAt) < AttributeResultsViewModel.staleAfter {
                known[job.id] = entry.items
            }
        }
        return known
    }

    /// Reads the run states of every chosen script, at most `maxInFlight` scripts at a time. Scripts in `known` are not read.
    private func run(_ jobs: [AttributeChoice], client: GraphClient, devices: [String: ManagedDevice], known: [String: [GraphItem<RunState>]]) async throws -> [JobOutcome] {
        try await withThrowingTaskGroup(of: JobOutcome.self) { group in
            var next = 0
            for _ in 0..<min(Self.maxInFlight, jobs.count) {
                let job = jobs[next]
                let items = known[job.id]
                next += 1
                group.addTask { try await Self.runJob(job, client: client, devices: devices, known: items) }
            }
            var outcomes: [JobOutcome] = []
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                completedJobs += 1
                if next < jobs.count {
                    let job = jobs[next]
                    let items = known[job.id]
                    next += 1
                    group.addTask { try await Self.runJob(job, client: client, devices: devices, known: items) }
                }
            }
            return outcomes
        }
    }

    private nonisolated static func runJob(_ job: AttributeChoice, client: GraphClient, devices: [String: ManagedDevice], known: [GraphItem<RunState>]?) async throws -> JobOutcome {
        let key = ResultsCache.key(config: job.config, script: job.script)
        do {
            let path = job.config.runStatesPath(scriptID: job.script.id)
            let items: [GraphItem<RunState>]
            var fullRead: CachedResults?
            if let known {
                items = known
            } else if let found = try await RunStateLookup.filtered(path: path, query: job.config.runStatesQuery, deviceIDs: Array(devices.keys), client: client) {
                items = found
            } else {
                items = AttributeResultsViewModel.unique(try await client.collectBySkip(RunState.self, path: path, query: job.config.runStatesQuery, maxInFlight: 2))
                fullRead = CachedResults(items: items, rows: items.map { AttributeRow(item: $0, config: job.config) }, inventory: [:], loadedAt: Date())
            }
            let rows = items.compactMap { item -> SearchResultRow? in
                guard let id = item.value.managedDevice?.id, let device = devices[id] else { return nil }
                return SearchResultRow.make(item: item, device: device, config: job.config, script: job.script)
            }
            return JobOutcome(key: key, rows: rows, fullRead: fullRead)
        } catch where isFatal(error) {
            throw error
        } catch {
            return JobOutcome(key: key, warning: "\(job.config.name) · \(job.script.title): \(job.config.message(for: error))")
        }
    }

    private nonisolated static func isFatal(_ error: Error) -> Bool {
        error is CancellationError || (error as? GraphError) == .unauthorized
    }

    private static func rowOrder(_ a: SearchResultRow, _ b: SearchResultRow) -> Bool {
        for (x, y) in [(a.deviceName, b.deviceName), (a.attribute, b.attribute)] {
            let order = x.localizedCaseInsensitiveCompare(y)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return a.id < b.id
    }
}
