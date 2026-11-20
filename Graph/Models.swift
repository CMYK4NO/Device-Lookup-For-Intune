import Foundation

struct ManagedDevice: Decodable, Equatable, Identifiable {
    let id: String
    let deviceName: String?
    let serialNumber: String?
    let userPrincipalName: String?
    let operatingSystem: String?
    let osVersion: String?
    let azureADDeviceId: String?
    /// Entra object id of the primary user. Managed apps are listed per user and device.
    var userId: String? = nil
    /// Last time the device contacted Intune, and when it was enrolled.
    var lastSyncDateTime: String? = nil
    var enrolledDateTime: String? = nil
}

extension ManagedDevice {
    var lastCheckIn: Date? { GraphDate.parse(lastSyncDateTime) }
    var enrolled: Date? { GraphDate.parse(enrolledDateTime) }
}

/// A custom attribute script, remediation or compliance script. Fields differ per OS, so all but `id` are optional.
struct ScriptSummary: Decodable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    let customAttributeName: String?
    let lastModifiedDateTime: String?
    /// Settings catalog policies call their name `name` and have a `platforms` value.
    var name: String? = nil
    var platforms: String? = nil
    /// Graph type name such as `#microsoft.graph.macOSCustomConfiguration`; tells which OS a policy or app is for.
    var odataType: String? = nil
    /// Set by apps (`isAssigned`) or by an expanded `assignments` list on policies; nil when Graph sent neither.
    var isAssigned: Bool? = nil
    var assignments: [Assignment]? = nil

    /// Only its presence matters, so no fields are decoded.
    struct Assignment: Decodable, Equatable {}

    /// False only when Graph said the item has no assignment; unknown counts as assigned so nothing is hidden by mistake.
    var hasAssignments: Bool { isAssigned ?? assignments.map { !$0.isEmpty } ?? true }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, customAttributeName, lastModifiedDateTime, isAssigned, assignments, name, platforms
        case odataType = "@odata.type"
    }
}

/// One device's result. Script run states carry an expanded `managedDevice`; compliance, configuration and app
/// device statuses describe the device with top-level fields, which are mapped onto the same shape.
struct RunState: Decodable, Equatable {
    let id: String
    let lastStateUpdateDateTime: String?
    let managedDevice: ManagedDevice?

    private enum Keys: String, CodingKey {
        case id, lastStateUpdateDateTime, managedDevice
        case lastReportedDateTime, lastSyncDateTime
        case deviceId, deviceName, deviceDisplayName, userPrincipalName, osVersion
    }

    init(id: String, lastStateUpdateDateTime: String?, managedDevice: ManagedDevice?) {
        self.id = id
        self.lastStateUpdateDateTime = lastStateUpdateDateTime
        self.managedDevice = managedDevice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        lastStateUpdateDateTime = try container.decodeIfPresent(String.self, forKey: .lastStateUpdateDateTime)
            ?? container.decodeIfPresent(String.self, forKey: .lastReportedDateTime)
            ?? container.decodeIfPresent(String.self, forKey: .lastSyncDateTime)
        if let nested = try container.decodeIfPresent(ManagedDevice.self, forKey: .managedDevice) {
            managedDevice = nested
        } else {
            let name = try container.decodeIfPresent(String.self, forKey: .deviceDisplayName)
                ?? container.decodeIfPresent(String.self, forKey: .deviceName)
            let deviceID = try container.decodeIfPresent(String.self, forKey: .deviceId)
            managedDevice = name == nil && deviceID == nil ? nil : ManagedDevice(
                id: deviceID ?? "",
                deviceName: name,
                serialNumber: nil,
                userPrincipalName: try container.decodeIfPresent(String.self, forKey: .userPrincipalName),
                operatingSystem: nil,
                osVersion: try container.decodeIfPresent(String.self, forKey: .osVersion),
                azureADDeviceId: nil
            )
        }
    }
}

/// A decoded item together with its raw JSON, for the Raw JSON inspector.
struct GraphItem<T> {
    let value: T
    let raw: String
}

struct GraphPage<T> {
    let items: [GraphItem<T>]
    let nextLink: URL?
}

extension ScriptSummary {
    var title: String { displayName ?? name ?? customAttributeName ?? id }
    var lastModified: Date? { GraphDate.parse(lastModifiedDateTime) }
}
