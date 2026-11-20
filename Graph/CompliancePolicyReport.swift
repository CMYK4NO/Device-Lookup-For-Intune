import Foundation

/// Per-device status of one settings catalog compliance policy, which is how Linux compliance is configured. These
/// policies have no `deviceStatuses` collection; Intune's "device status" report for a compliance policy is used instead.
/// The report is undocumented, so no columns are requested (an empty `select` returns all of them) and the ones that name the
/// device, user, state and time are found by their usual names. Every column stays in the Raw JSON.
enum CompliancePolicyReport {
    static let path = "/deviceManagement/reports/getDeviceStatusByCompliacePolicyReport"

    private static let keys: [(key: String, columns: [String])] = [
        ("deviceName", ["DeviceName", "DeviceDisplayName"]),
        ("userPrincipalName", ["UPN", "UserPrincipalName", "UserName"]),
        ("deviceId", ["IntuneDeviceId", "DeviceId"]),
        ("status", ["PolicyStatus_loc", "PolicyStatus", "ComplianceState", "Status"]),
        ("osVersion", ["OS"]),
        ("lastSyncDateTime", ["LastContact", "LastReportedDateTime", "LastModifiedDateTime"]),
    ]

    static func items(
        policyID: String,
        client: GraphClient,
        progress: (@MainActor (Int) -> Void)? = nil
    ) async throws -> [GraphItem<RunState>] {
        let policy = try DeviceStatusLoader.segment(policyID)
        let rows = try await ReportReader.rows(path: path, filter: "(PolicyId eq '\(policy)')", pageSize: 1000, client: client, progress: progress)
        return try rows.map(item)
    }

    static func item(_ row: [String: String]) throws -> GraphItem<RunState> {
        var json = row
        for (key, columns) in keys where json[key] == nil {
            json[key] = columns.lazy.compactMap { name in row.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }.first
        }
        json["id"] = json["deviceId"] ?? json["deviceName"] ?? UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        return GraphItem(value: try JSONDecoder().decode(RunState.self, from: data), raw: String(decoding: data, as: UTF8.self))
    }
}
