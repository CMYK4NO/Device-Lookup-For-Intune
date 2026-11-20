import SwiftUI

/// The compliance, configuration or managed apps rows of the selected devices, with the columns of that part.
struct StatusResultsView: View {
    let part: StatusPart
    let rows: [StatusRow]

    var body: some View {
        switch part {
        case .compliance, .configuration:
            // The columns of an attribute's table, after the policy or profile the row is about.
            Table(rows) {
                TableColumn(part.itemTitle) { Text($0.name).textSelection(.enabled) }
                TableColumn("Device") { Text($0.device).textSelection(.enabled) }
                TableColumn("User (UPN)") { Text($0.user).textSelection(.enabled) }
                TableColumn("Serial") { Text($0.serial).textSelection(.enabled) }
                TableColumn("OS version") { Text($0.osVersion).textSelection(.enabled) }
                TableColumn("Run state") { Text($0.state).textSelection(.enabled) }
                TableColumn("Last updated") { Text(TableText.date($0.date)).textSelection(.enabled).help(dateHelp) }
            }
        case .apps:
            Table(rows) {
                TableColumn("Device") { Text($0.device).textSelection(.enabled) }
                TableColumn("OS") { Text($0.os).textSelection(.enabled) }
                TableColumn("Serial") { Text($0.serial).textSelection(.enabled) }
                TableColumn("App") { Text($0.name).textSelection(.enabled) }
                TableColumn("Version") { Text($0.version).textSelection(.enabled) }
                TableColumn("Status") { Text($0.state).textSelection(.enabled) }
                TableColumn("Date") { Text(TableText.date($0.date)).textSelection(.enabled).help(dateHelp) }
            }
        }
    }

    /// What the date in a row means, shown on hover.
    private var dateHelp: String {
        switch part {
        case .compliance: return "When the device last reported its compliance with this policy."
        case .configuration: return "When Intune last updated the profile's status on this device. Intune keeps no install date for profiles."
        case .apps: return "When the app's install status last changed on this device."
        }
    }
}

/// The table of one part, or why there is none. It observes the status itself, because the search view does not
/// redraw when a part finishes loading.
struct StatusResultsPane: View {
    @ObservedObject var status: DeviceStatusViewModel
    let part: StatusPart
    let devices: [ManagedDevice]

    var body: some View {
        let rows = StatusRows.make(part, devices: devices, statuses: status.statuses)
        if !rows.isEmpty {
            StatusResultsView(part: part, rows: rows)
        } else {
            VStack {
                Text(status.isLoading ? "Loading…" : status.errorMessage != nil ? "" : StatusRows.emptyMessage(part))
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
