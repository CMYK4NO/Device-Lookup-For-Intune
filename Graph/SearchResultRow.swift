import Foundation

/// One attribute result for one of the searched user's devices.
struct SearchResultRow: Identifiable, Equatable, Sendable {
    let id: String
    let deviceID: String
    let deviceName: String
    let osID: String
    let os: String
    let serial: String
    let attribute: String
    let value: String
    let runState: String
    let lastUpdated: Date?

    static func make(item: GraphItem<RunState>, device: ManagedDevice, config: OSSourceConfig, script: ScriptSummary) -> SearchResultRow {
        let state = item.value
        let fields = RunStateFields(raw: item.raw, config: config)
        return SearchResultRow(
            id: "\(config.id)/\(script.id)/\(state.id)",
            deviceID: device.id,
            deviceName: device.deviceName ?? "",
            osID: config.id,
            os: config.name,
            serial: device.serialNumber ?? "",
            attribute: script.title,
            value: fields.value,
            runState: fields.runState,
            lastUpdated: GraphDate.parse(state.lastStateUpdateDateTime)
        )
    }
}
