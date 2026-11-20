import Foundation

/// One table row: a device's result for the selected attribute.
struct AttributeRow: Identifiable, Equatable {
    let id: String
    let deviceID: String
    let device: String
    let user: String
    let serial: String
    let osVersion: String
    /// Operating system from the expanded managed device; Graph often returns null here.
    let deviceOS: String
    let value: String
    /// True when the configured value field was empty and `value` lists all populated fields instead.
    let valueIsFallback: Bool
    let runState: String
    let lastUpdated: Date?
    let raw: String
    let searchText: String

    var lastUpdatedSort: Date { lastUpdated ?? .distantPast }

    init(item: GraphItem<RunState>, config: OSSourceConfig, serials: [String: String] = [:]) {
        let state = item.value
        let device = state.managedDevice
        let fields = RunStateFields(raw: item.raw, config: config)
        id = state.id
        deviceID = device?.id ?? ""
        self.device = device?.deviceName ?? ""
        user = device?.userPrincipalName ?? ""
        serial = device?.serialNumber ?? device.flatMap { serials[$0.id] } ?? ""
        osVersion = device?.osVersion ?? ""
        deviceOS = device?.operatingSystem ?? ""
        runState = fields.runState
        value = fields.value
        valueIsFallback = fields.valueIsFallback
        lastUpdated = GraphDate.parse(state.lastStateUpdateDateTime)
        raw = item.raw
        searchText = [self.device, user, serial, osVersion, value, runState].joined(separator: " ")
    }
}
