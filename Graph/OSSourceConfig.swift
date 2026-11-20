import Foundation

/// Maps one OS to its Graph endpoints and the fields that hold the script output and run state.
/// This is the single place to fix if a property name turns out to be wrong.
struct OSSourceConfig: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var listPath: String
    var listQuery: [URLQueryItem]
    let runStatesQuery: [URLQueryItem]
    /// Field with the script output. If it is empty, all populated fields are shown instead.
    let valueField: String
    /// Field with the per-device state (macOS: `runState`; remediations and compliance scripts: `detectionState`).
    let runStateField: String
    /// What the sidebar list holds, for empty-list text.
    var itemName = "attributes"
    /// The results collection under each listed item.
    var resultsSegment = "deviceRunStates"
    /// When the value field is empty, list all populated fields instead. Only meaningful for script output.
    var fallsBack = true
    /// Whether serial numbers are filled from the device inventory. Needs a device id in the results.
    var fillsInventory = true
    /// Apps are read with DeviceManagementApps.Read.All, which is requested only for them.
    var requiresApps = false
    /// Policies and apps are listed for every OS together; these lower-case type-name prefixes pick the ones of this OS.
    /// Empty means no filtering. Items without a type are kept, so an unexpected answer still shows something.
    var typePrefixes: [String] = []
    /// Lists only items that are assigned to something; unassigned policies and apps do nothing on any device.
    var onlyAssigned = false
    /// For status sources: keeps only devices of this OS. The statuses name their device but not its OS, so the
    /// names are matched against the Intune device list. Policies list every device in the tenant, others as `notApplicable`.
    var osName: String? = nil
    /// Results come from a report instead of a `deviceStatuses` collection.
    var report: StatusReport? = nil
    /// For lists that mix platforms: keeps only items whose `platforms` is this value (Linux compliance policies).
    var platform: String? = nil
    /// Whether the table has a Value column. Compliance statuses have no output worth showing there.
    var showsValue = true
    /// Raw states shown under another name (and so also filtered, sorted and exported under it).
    var runStateLabels: [String: String] = [:]

    /// The sign-in configuration this source needs.
    func authConfiguration(_ base: AuthConfiguration) -> AuthConfiguration {
        requiresApps ? base.withApps : base
    }

    func runStatesPath(scriptID: String) -> String {
        "\(listPath)/\(scriptID)/\(resultsSegment)"
    }

    /// User-facing text for a failed run-state request. Intune answers "No OData route" when it has no run-state endpoint for these scripts.
    func message(for error: Error) -> String {
        if case GraphError.http(400, let detail?) = error, detail.contains("No OData route") {
            return "\(name) results are not available: Intune has no per-device run-state endpoint for these scripts in this tenant."
        }
        return error.localizedDescription
    }

    private static let expandDevice = URLQueryItem(
        name: "$expand",
        value: "managedDevice($select=id,deviceName,serialNumber,userPrincipalName,operatingSystem,osVersion)"
    )

    /// Results can cover thousands of devices, so the largest page keeps the number of requests down.
    private static let pageSize = URLQueryItem(name: "$top", value: "1000")

    private static let expandAssignments = URLQueryItem(name: "$expand", value: "assignments")

    private static func listSelect(_ fields: String) -> [URLQueryItem] {
        [URLQueryItem(name: "$select", value: fields)]
    }

    static let macOS = OSSourceConfig(
        id: "macOS",
        name: "macOS",
        symbol: "desktopcomputer",
        listPath: "/deviceManagement/deviceCustomAttributeShellScripts",
        listQuery: listSelect("id,displayName,customAttributeName,lastModifiedDateTime"),
        runStatesQuery: [expandDevice, pageSize],
        valueField: "resultMessage",
        runStateField: "runState"
    )

    /// Remediations (detection output). Field names are unverified against a live tenant.
    static let windows = OSSourceConfig(
        id: "windows",
        name: "Windows",
        symbol: "pc",
        listPath: "/deviceManagement/deviceHealthScripts",
        listQuery: listSelect("id,displayName,lastModifiedDateTime"),
        runStatesQuery: [expandDevice, pageSize],
        valueField: "preRemediationDetectionScriptOutput",
        runStateField: "detectionState"
    )

    /// Custom compliance discovery scripts. Field names are unverified against a live tenant.
    static let linux = OSSourceConfig(
        id: "linux",
        name: "Linux",
        symbol: "terminal",
        listPath: "/deviceManagement/deviceComplianceScripts",
        listQuery: listSelect("id,displayName,lastModifiedDateTime"),
        runStatesQuery: [expandDevice, pageSize],
        valueField: "scriptOutput",
        runStateField: "detectionState"
    )

    static let all = [macOS, windows, linux]

    /// Compliance policies, configuration profiles and apps, each across all operating systems. The results are
    /// per-device statuses, so the device is described by top-level fields instead of an expanded managedDevice.
    static let compliance = OSSourceConfig(
        id: "compliance",
        name: "Compliance",
        symbol: "checkmark.shield",
        listPath: "/deviceManagement/deviceCompliancePolicies",
        listQuery: listSelect("id,displayName,lastModifiedDateTime") + [expandAssignments],
        runStatesQuery: [pageSize],
        valueField: "deviceModel",
        runStateField: "status",
        itemName: "assigned compliance policies",
        resultsSegment: "deviceStatuses",
        fallsBack: false,
        fillsInventory: false,
        onlyAssigned: true,
        showsValue: false
    )

    /// Legacy configuration profiles only; settings catalog policies live under a different endpoint.
    static let configurations = OSSourceConfig(
        id: "configurations",
        name: "Configurations",
        symbol: "slider.horizontal.3",
        listPath: "/deviceManagement/deviceConfigurations",
        listQuery: listSelect("id,displayName,lastModifiedDateTime") + [expandAssignments],
        runStatesQuery: [pageSize],
        valueField: "deviceModel",
        runStateField: "status",
        itemName: "assigned configuration profiles",
        resultsSegment: "deviceStatuses",
        fallsBack: false,
        fillsInventory: false,
        onlyAssigned: true,
        showsValue: false
    )

    static let apps = OSSourceConfig(
        id: "apps",
        name: "Managed apps",
        symbol: "square.stack.3d.up",
        listPath: "/deviceAppManagement/mobileApps",
        // No server-side filter: `isAssigned eq true` made Intune time out (504). Assigned apps are picked client-side.
        listQuery: listSelect("id,displayName,lastModifiedDateTime,isAssigned") + [URLQueryItem(name: "$top", value: "100")],
        runStatesQuery: [],
        valueField: "installStateDetail",
        runStateField: "installState",
        itemName: "assigned apps",
        resultsSegment: "deviceStatuses",
        fallsBack: false,
        fillsInventory: true,
        requiresApps: true,
        onlyAssigned: true,
        report: .appInstall
    )

    /// Whether a listed policy or app belongs to this source's OS.
    func accepts(_ script: ScriptSummary) -> Bool {
        if onlyAssigned, !script.hasAssignments { return false }
        if let platform, let platforms = script.platforms, platforms.caseInsensitiveCompare(platform) != .orderedSame { return false }
        guard !typePrefixes.isEmpty, let type = script.odataType?.lowercased() else { return true }
        let name = type.hasPrefix("#microsoft.graph.") ? String(type.dropFirst("#microsoft.graph.".count)) : type
        return typePrefixes.contains { name.hasPrefix($0) }
    }

    /// A status source narrowed to one OS. Linux has no policy or app types in these endpoints, so its lists are normally empty.
    private static func scoped(_ base: OSSourceConfig, to os: OSSourceConfig, prefixes: [String]) -> OSSourceConfig {
        var config = base
        config.id = "\(base.id)-\(os.id)"
        config.name = os.name
        config.osName = os.name
        config.symbol = os.symbol
        config.typePrefixes = prefixes
        return config
    }

    private static func perOS(_ base: OSSourceConfig) -> [OSSourceConfig] {
        [scoped(base, to: macOS, prefixes: ["macos"]),
         scoped(base, to: windows, prefixes: ["windows", "win32", "officesuiteapp"]),
         scoped(base, to: linux, prefixes: ["linux"])]
    }

    /// Linux compliance policies are settings catalog policies, listed under a different endpoint and read from a report.
    static let complianceSources: [OSSourceConfig] = perOS(compliance).map { source in
        var source = source
        if source.osName == "Linux" {
            source.listPath = "/deviceManagement/compliancePolicies"
            source.listQuery = []
            source.platform = "linux"
            source.typePrefixes = []
            source.report = .compliancePolicy
        }
        return source
    }
    /// On macOS a profile that is `compliant` or `remediated` is applied either way, so both read "Succeeded".
    static let configurationSources: [OSSourceConfig] = perOS(configurations).map { source in
        var source = source
        if source.osName == "macOS" { source.runStateLabels = ["compliant": "Succeeded", "remediated": "Succeeded"] }
        return source
    }
    static let appSources = perOS(apps)

    /// Every source the sidebar can open.
    static let allSources = all + complianceSources + configurationSources + appSources
}

/// Where a source reads its per-device results from when it is not a `deviceStatuses` collection.
enum StatusReport: Equatable {
    case appInstall, compliancePolicy

    func items(id: String, client: GraphClient, progress: (@MainActor (Int) -> Void)?) async throws -> [GraphItem<RunState>] {
        switch self {
        case .appInstall: return try await AppInstallReport.items(appID: id, client: client, progress: progress)
        case .compliancePolicy: return try await CompliancePolicyReport.items(policyID: id, client: client, progress: progress)
        }
    }
}
