import Foundation

struct CompliancePolicy: Identifiable, Equatable {
    let id: String
    let name: String
    let state: String?
    /// The user the policy was evaluated for (the report's `UPN`); Intune reports a policy once per user of the device.
    var user: String? = nil
    /// When the device last reported its compliance with the policy (the compliance report's `LastContact`).
    var lastReported: Date? = nil
}

struct ConfigurationItem: Identifiable, Equatable {
    let id: String
    let name: String
    let state: String?
    /// The user the profile's status was reported for (the report's `UPN`).
    var user: String? = nil
    /// When Intune last updated the profile's status on the device (the report's `PspdpuLastModifiedTimeUtc`).
    /// Intune keeps no install date for a profile.
    var lastUpdated: Date? = nil
}

struct AppItem: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String?
    let installState: String?
    /// When the app's install status last changed on the device (the app install report's `LastModifiedDateTime`).
    var lastModified: Date? = nil
}

enum StatusPart: Hashable {
    case compliance, configuration, apps

    var title: String {
        switch self {
        case .compliance: return "Compliance"
        case .configuration: return "Configuration"
        case .apps: return "Managed apps"
        }
    }

    /// The column that names the row's item.
    var itemTitle: String {
        switch self {
        case .compliance: return "Policy"
        case .configuration: return "Profile"
        case .apps: return "App"
        }
    }
}

/// Compliance, configuration profiles and managed apps of one device. Each part is loaded when its tab is opened.
struct DeviceStatus: Equatable {
    var compliancePolicies: [CompliancePolicy] = []
    var configurations: [ConfigurationItem] = []
    var apps: [AppItem] = []
    /// Parts that could not be read, each starting with its section name.
    var notes: [String] = []
    /// Parts that were read without a note, so they need no second request.
    var loaded: Set<StatusPart> = []

    mutating func apply(_ part: StatusPart, from other: DeviceStatus) {
        switch part {
        case .compliance:
            compliancePolicies = other.compliancePolicies
        case .configuration:
            configurations = other.configurations
        case .apps:
            apps = other.apps
        }
        notes.removeAll { $0.hasPrefix(part.title) }
        notes += other.notes
        // A part that failed is not marked loaded, so opening its tab again retries.
        if other.notes.isEmpty { loaded.insert(part) } else { loaded.remove(part) }
    }
}

/// Turns Graph enum values such as `nonCompliant` or `notInstalled` into text.
enum StateText {
    static func readable(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Unknown" }
        switch raw {
        case "noncompliant", "nonCompliant": return "Not compliant"
        case "configManager": return "Managed by Configuration Manager"
        default:
            var words = ""
            for character in raw {
                if character.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(character)
            }
            return words.prefix(1).uppercased() + words.dropFirst().lowercased()
        }
    }

    static func isFailedInstall(_ raw: String?) -> Bool {
        raw == "failed" || raw == "uninstallFailed"
    }

    /// The app states worth showing: installed, or failed.
    static func isInstalledOrFailed(_ raw: String?) -> Bool {
        raw == "installed" || isFailedInstall(raw)
    }

}

enum DeviceStatusLoader {
    private struct AppIntentAndState: Decodable {
        struct App: Decodable {
            let applicationId: String?
            let displayName: String?
            let displayVersion: String?
            let installState: String?
        }
        let mobileAppList: [App]?
    }

    /// Reads one part. A failure (403, throttling, …) becomes a note; sign-in errors and cancellation abort.
    /// Parts are read separately, when their tab is opened, to keep the request count low: Intune throttles quickly.
    static func load(_ part: StatusPart, for device: ManagedDevice, client: GraphClient) async throws -> DeviceStatus {
        var status = DeviceStatus()
        let id = try DeviceSecretsLoader.guid(device.id)
        do {
            switch part {
            case .compliance:
                status.compliancePolicies = try await compliance(id, client)
            case .configuration:
                status.configurations = try await configurations(id, client)
            case .apps:
                guard let userId = device.userId, !userId.isEmpty else {
                    status.notes.append("\(part.title): the device has no primary user, so its apps cannot be listed.")
                    return status
                }
                status.apps = try await apps(of: device, userId: userId, deviceID: id, client)
            }
        } catch where isFatal(error) {
            throw error
        } catch {
            status.notes.append("\(part.title): \(error.localizedDescription)")
        }
        return status
    }

    private static let compliancePath = "/deviceManagement/reports/getDevicePoliciesComplianceReport"

    /// Every compliance policy of the device, with its state, user and when the device last reported it. This is the report
    /// the Intune admin center reads for a device's compliance; `deviceCompliancePolicyStates` has no date. Like the admin
    /// center, it has a row per policy and user.
    private static func compliance(_ id: String, _ client: GraphClient) async throws -> [CompliancePolicy] {
        try await ReportReader.rows(path: compliancePath, filter: "(DeviceId eq '\(id)')", pageSize: 50, client: client)
            .map { row in
                let name = row["PolicyName"] ?? row["PolicyId"] ?? "Unnamed policy"
                return CompliancePolicy(id: row["PolicyId"] ?? name, name: name, state: row["PolicyStatus_loc"] ?? row["PolicyStatus"],
                                        user: row["UPN"], lastReported: GraphDate.parse(row["LastContact"]))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Intune retired `managedDevices/{id}/deviceConfigurationStates` (MC688107); the device's policies now come from a report.
    /// The answer is `Schema` (column names) plus `Values` (rows in that order), paged with skip/top.
    private static func configurations(_ id: String, _ client: GraphClient) async throws -> [ConfigurationItem] {
        let url = try client.url(path: "/deviceManagement/reports/getConfigurationPoliciesReportForDevice")
        let pageSize = 50
        let policyTypes = ["Microsoft.Management.Services.Api.DeviceConfiguration", "DeviceManagementConfigurationPolicy",
                           "DeviceConfigurationAdmxPolicy", "Microsoft.Management.Services.Api.DeviceManagementIntent"]
            .map { "(PolicyBaseTypeName eq '\($0)')" }.joined(separator: " or ")
        var items: [ConfigurationItem] = []
        for page in 0..<40 {
            let data = try await client.post(url: url, json: [
                "select": ["IntuneDeviceId", "PolicyBaseTypeName", "PolicyId", "PolicyStatus", "UPN", "UserId", "PspdpuLastModifiedTimeUtc", "PolicyName", "UnifiedPolicyType"],
                "filter": "(\(policyTypes)) and (IntuneDeviceId eq '\(id)')",
                "orderBy": ["PolicyName"],
                "skip": page * pageSize,
                "top": pageSize,
            ])
            let rows = try ReportTable(data).rows
            items += rows.map {
                ConfigurationItem(
                    id: $0["PolicyId"] ?? UUID().uuidString, name: $0["PolicyName"] ?? $0["PolicyId"] ?? "Unnamed policy",
                    state: $0["PolicyStatus"], user: $0["UPN"], lastUpdated: GraphDate.parse($0["PspdpuLastModifiedTimeUtc"])
                )
            }
            if rows.count < pageSize { break }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func apps(of device: ManagedDevice, userId: String, deviceID: String, _ client: GraphClient) async throws -> [AppItem] {
        let url = try client.url(path: "/users/\(try DeviceSecretsLoader.guid(userId))/mobileAppIntentAndStates/\(deviceID)")
        let list = try await client.get(AppIntentAndState.self, url: url).mobileAppList ?? []
        var apps = list.enumerated().map { index, app in
            AppItem(id: app.applicationId ?? "app-\(index)", name: app.displayName ?? app.applicationId ?? "Unnamed app",
                    version: app.displayVersion, installState: app.installState)
        }
        let dates = try await installDates(of: apps.filter { StateText.isInstalledOrFailed($0.installState) }, on: device, client)
        for index in apps.indices { apps[index].lastModified = dates[apps[index].id] }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// When each app's install status last changed on the device, by app id. `mobileAppIntentAndStates` has no dates, so
    /// they come from each app's install status report (the admin center's Device install status of the app), two apps at
    /// a time. That report cannot be filtered by device: it is searched for the device name and the row is picked by id.
    private static func installDates(of apps: [AppItem], on device: ManagedDevice, _ client: GraphClient) async throws -> [String: Date] {
        let targets = apps.compactMap { app in (try? DeviceSecretsLoader.guid(app.id)).map { (key: app.id, guid: $0) } }
        let deviceIDs = Set([device.id, device.azureADDeviceId].compactMap { $0?.lowercased() })
        let deviceName = device.deviceName
        return try await withThrowingTaskGroup(of: (String, Date?).self) { group in
            var next = 0
            func start() {
                let target = targets[next]
                next += 1
                group.addTask { (target.key, try await Self.installDate(appID: target.guid, deviceIDs: deviceIDs, deviceName: deviceName, client)) }
            }
            for _ in 0..<min(2, targets.count) { start() }
            var dates: [String: Date] = [:]
            while let result = try await group.next() {
                dates[result.0] = result.1
                if next < targets.count { start() }
            }
            return dates
        }
    }

    /// One app's row for the device, or nil when the report fails or does not list the device: the app is still shown.
    private static func installDate(appID: String, deviceIDs: Set<String>, deviceName: String?, _ client: GraphClient) async throws -> Date? {
        do {
            let rows = try await ReportReader.rows(
                path: AppInstallReport.path, filter: "(ApplicationId eq '\(appID)')", select: ["DeviceId", "DeviceName", "LastModifiedDateTime"],
                search: deviceName, pageSize: 1000, limit: 1000, client: client
            )
            return rows.first { deviceIDs.contains(($0["DeviceId"] ?? "").lowercased()) }.flatMap { GraphDate.parse($0["LastModifiedDateTime"]) }
        } catch where !isFatal(error) {
            return nil
        }
    }

    /// Ids that Graph returns and that go into a URL path must be plain identifiers.
    static func segment(_ text: String) throws -> String {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw GraphError.invalidRequest
        }
        return text
    }

    private static func isFatal(_ error: Error) -> Bool {
        error is CancellationError || (error as? GraphError) == .unauthorized
    }
}
