import Foundation

/// One line of the compliance, configuration or managed apps table of the selected devices.
struct StatusRow: Identifiable, Equatable {
    let id: String
    let device: String
    let os: String
    let serial: String
    /// Policy, profile or app.
    let name: String
    /// The app version.
    let version: String
    let state: String
    /// The user a policy or profile was reported for.
    var user = ""
    var osVersion = ""
    /// When the device last reported a compliance policy, when an app's install status last changed, or when a profile's
    /// status was last updated (Intune keeps no install date for profiles).
    var date: Date? = nil
}

enum StatusRows {
    /// Rows of one part for the devices whose part has been read, in the order of `devices`.
    static func make(_ part: StatusPart, devices: [ManagedDevice], statuses: [String: DeviceStatus]) -> [StatusRow] {
        devices.flatMap { device -> [StatusRow] in
            guard let status = statuses[device.id], status.loaded.contains(part) else { return [] }
            func row(_ index: Int, _ name: String, version: String? = nil, state: String? = nil, user: String? = nil, date: Date?) -> StatusRow {
                StatusRow(
                    id: "\(device.id)|\(part.title)|\(index)", device: device.deviceName ?? device.id,
                    os: device.operatingSystem ?? "", serial: device.serialNumber ?? "",
                    name: name, version: version ?? "", state: StateText.readable(state),
                    user: user ?? "", osVersion: device.osVersion ?? "", date: date
                )
            }
            switch part {
            case .compliance:
                return status.compliancePolicies.enumerated().map {
                    row($0.offset, $0.element.name, state: $0.element.state, user: $0.element.user, date: $0.element.lastReported)
                }
            case .configuration:
                return status.configurations.enumerated().map {
                    row($0.offset, $0.element.name, state: $0.element.state, user: $0.element.user, date: $0.element.lastUpdated)
                }
            case .apps:
                return status.apps
                    .filter { StateText.isInstalledOrFailed($0.installState) }
                    .sorted {
                        let failed = (StateText.isFailedInstall($0.installState), StateText.isFailedInstall($1.installState))
                        if failed.0 != failed.1 { return failed.0 }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    .enumerated().map { row($0.offset, $0.element.name, version: $0.element.version, state: $0.element.installState, date: $0.element.lastModified) }
            }
        }
    }

    static func emptyMessage(_ part: StatusPart) -> String {
        switch part {
        case .compliance: return "No compliance result reported for the selected devices."
        case .configuration: return "No configuration profiles reported for the selected devices."
        case .apps: return "No installed or failed apps reported for the selected devices."
        }
    }
}
