import Foundation

/// Per-device install status of one app. Intune retired `mobileApps/{id}/deviceStatuses`; the status now comes from a
/// report. Its rows are turned into the same run-state JSON the other sources return, so one table shows them all.
enum AppInstallReport {
    static let path = "/deviceManagement/reports/microsoft.graph.retrieveDeviceAppInstallationStatusReport"
    private static let columns = ["DeviceName", "UserPrincipalName", "Platform", "AppVersion", "DeviceId",
                                  "LastModifiedDateTime", "AppInstallState", "AppInstallStateDetails", "HexErrorCode"]

    static func items(
        appID: String,
        client: GraphClient,
        progress: (@MainActor (Int) -> Void)? = nil
    ) async throws -> [GraphItem<RunState>] {
        let app = try DeviceStatusLoader.segment(appID)
        let rows = try await ReportReader.rows(path: path, filter: "(ApplicationId eq '\(app)')", select: columns, pageSize: 1000, client: client, progress: progress)
        return try rows.map(item)
    }

    private static func item(_ row: [String: String]) throws -> GraphItem<RunState> {
        var json: [String: String] = [:]
        let names = ["DeviceName": "deviceName", "UserPrincipalName": "userPrincipalName", "DeviceId": "deviceId",
                     "LastModifiedDateTime": "lastSyncDateTime", "AppInstallState": "installState",
                     "AppInstallStateDetails": "installStateDetail", "Platform": "platform",
                     "AppVersion": "appVersion", "HexErrorCode": "hexErrorCode"]
        for (column, key) in names { json[key] = row[column] }
        json["id"] = row["DeviceId"] ?? row["DeviceName"] ?? UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        return GraphItem(value: try JSONDecoder().decode(RunState.self, from: data), raw: String(decoding: data, as: UTF8.self))
    }
}
