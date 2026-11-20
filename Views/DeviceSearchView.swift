import SwiftUI

struct DeviceSearchView: View {
    @ObservedObject var model: DeviceSearchViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var auth: AuthService
    @State private var exportError: String?
    @State private var tab = StatusTab.compliance
    @State private var resultSelection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding(12)
            devicesPanel
            secretsPanel
            statusPanel
            Divider()
            results
            warningsFooter
        }
        .task(id: model.selection) {
            guard !model.selection.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            loadAttributes()
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// List writes its selection while SwiftUI is updating views; publishing that directly triggers a runtime warning.
    private var selection: Binding<Set<String>> {
        Binding(
            get: { model.selection },
            set: { newValue in DispatchQueue.main.async { if model.selection != newValue { model.selection = newValue } } }
        )
    }

    private var canRead: Bool {
        !model.chosenAttributes.isEmpty && !model.isSearching
    }

    private var canSearch: Bool {
        auth.account != nil && settings.authConfiguration != nil
            && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(model.mode.prompt, text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                    .disabled(model.isSearching)
                if model.isSearching {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Search", action: search)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSearch)
                }
            }
            HStack(spacing: 12) {
                Picker("OS", selection: $model.osFilter) {
                    Text("All OS").tag(String?.none)
                    ForEach(OSSourceConfig.all) { Text($0.name).tag(String?.some($0.id)) }
                }
                .fixedSize()
                Spacer()
                Button("Export CSV") { export() }
                    .disabled(model.isSearching || (shownPart == nil && model.visibleRows.isEmpty))
                if model.isSearching { ProgressView().controlSize(.small) }
                if let status = model.statusText { Text(status).foregroundStyle(.secondary) }
            }
            if auth.account == nil {
                Text("Sign in on the Account page first.").foregroundStyle(.secondary)
            }
        }
    }

    /// The compliance, configuration or managed apps part whose table fills the results area, if one does.
    private var shownPart: StatusPart? {
        model.selectedDevices.isEmpty ? nil : tab.part
    }

    @ViewBuilder private var results: some View {
        if let part = shownPart {
            StatusResultsPane(status: model.status, part: part, devices: model.selectedDevices)
        } else if let message = model.errorMessage {
            note(message, color: .red)
        } else if let message = model.infoMessage {
            note(message, color: .secondary)
        } else if !model.hasSearched {
            note(model.mode.startMessage, color: .secondary)
        } else if !model.hasRead {
            note(model.choices.isEmpty ? "Select one or more devices above to list their attributes." : "Tick the attributes to read, then choose Read.", color: .secondary)
        } else if let message = model.emptyResultsMessage {
            note(message, color: .secondary)
        } else {
            VStack(spacing: 0) {
                flatTable
                resultDetail
            }
        }
    }

    /// The user's machines from the Intune inventory, shown as soon as they are found.
    @ViewBuilder private var devicesPanel: some View {
        if !model.devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Devices in Intune (\(model.visibleDevices.count))").font(.headline)
                Table(model.visibleDevices, selection: selection) {
                    TableColumn("Device") { Text($0.deviceName ?? $0.id) }
                    TableColumn("OS") { Text($0.operatingSystem ?? "") }
                    TableColumn("OS version") { Text($0.osVersion ?? "") }
                    TableColumn("Last check-in") { Text(format($0.lastCheckIn)) }
                    TableColumn("Enrolled") { Text(format($0.enrolled)) }
                    TableColumn("Serial") { Text($0.serialNumber ?? "") }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    CopyMenu(rows: model.visibleDevices.filter { ids.contains($0.id) }.map(\.copyFields))
                }
                .onCopyCommand {
                    TableText.items(for: model.visibleDevices.filter { model.selection.contains($0.id) }.map(\.copyFields))
                }
                .frame(height: min(CGFloat(model.visibleDevices.count) * 28 + 36, 300))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var secretsPanel: some View {
        if !model.secretDevices.isEmpty {
            SecretsPanelView(model: model.secrets, devices: model.secretDevices, reveal: revealSecrets, rotate: rotateSecret)
        }
    }

    @ViewBuilder private var statusPanel: some View {
        if !model.selectedDevices.isEmpty {
            DeviceStatusPanelView(model: model.status, tab: $tab, devices: model.selectedDevices, load: loadStatus) { attributesPanel }
        }
    }

    /// The attributes of the selected devices' OS; only the ticked ones are read.
    @ViewBuilder private var attributesPanel: some View {
        if model.choices.isEmpty {
            Text(model.isLoadingAttributes ? "Loading attributes…" : "No attributes to list for these devices.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Attributes (\(model.choices.count))").font(.headline)
                    Button("Select all") { model.selectAllAttributes() }.buttonStyle(.link)
                    Button("Clear") { model.clearAttributeSelection() }.buttonStyle(.link)
                    Spacer()
                    Button("Read (\(model.chosenAttributes.count))") { read() }
                        .disabled(!canRead)
                }
                List(model.choices) { choice in
                    Toggle(isOn: Binding(
                        get: { model.chosenAttributes.contains(choice.id) },
                        set: { _ in model.toggleAttribute(choice.id) }
                    )) {
                        HStack(spacing: 10) {
                            Text(choice.script.title).fontWeight(.medium)
                            Text(choice.config.name).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                .frame(height: min(CGFloat(model.choices.count) * 28 + 8, 200))
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        VStack {
            Text(text).foregroundStyle(color).textSelection(.enabled).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Right-click a row to copy one column or the whole row; ⌘C copies the selected row. Cells stay plain text, because
    /// selectable text in a cell takes the click that selects the row.
    private var flatTable: some View {
        Table(model.visibleRows, selection: $resultSelection) {
            TableColumn("Custom Attribute") { Text($0.attribute) }
            TableColumn("Device") { Text($0.deviceName) }
            TableColumn("OS") { Text($0.os) }
            TableColumn("Serial") { Text($0.serial) }
            TableColumn("Value") { ValueCell(value: $0.value) }
                .width(min: 120, ideal: resultValueWidth)
            TableColumn("Result") { Text($0.runState) }
            TableColumn("Date") { Text(format($0.lastUpdated)) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            CopyMenu(rows: model.visibleRows.filter { ids.contains($0.id) }.map(\.copyFields))
        }
        .onCopyCommand {
            TableText.items(for: model.visibleRows.filter { $0.id == resultSelection }.map(\.copyFields))
        }
    }

    private var resultValueWidth: CGFloat {
        ValueCell.idealWidth(for: model.visibleRows.lazy.map(\.value))
    }

    /// The selected result's whole value, wrapped and selectable: a table row is one line high on macOS.
    @ViewBuilder private var resultDetail: some View {
        if let row = model.visibleRows.first(where: { $0.id == resultSelection }) {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.attribute) · \(row.deviceName)").font(.headline)
                    Text(row.value.isEmpty ? "No value reported." : row.value)
                        .foregroundStyle(row.value.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(height: 110)
        }
    }

    @ViewBuilder private var warningsFooter: some View {
        if !model.warnings.isEmpty {
            Text("\(model.warnings.count) source(s) could not be read. First: \(model.warnings[0])")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .padding(8)
                .help(model.warnings.joined(separator: "\n"))
        }
    }

    private func format(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
    }

    private func search() {
        guard canSearch, let configuration = settings.authConfiguration else { return }
        model.beginSearch(client: auth.graphClient(configuration))
    }

    private func loadStatus(_ part: StatusPart) {
        guard let configuration = settings.authConfiguration else { return }
        model.status.begin(part, devices: model.selectedDevices, client: auth.graphClient(configuration))
    }

    private func loadAttributes() {
        guard !model.selection.isEmpty, let configuration = settings.authConfiguration else { return }
        model.beginLoadAttributes(client: auth.graphClient(configuration))
    }

    /// Exports the table on screen: the attribute results (with the OS filter applied), or the compliance, configuration
    /// or managed apps table of the selected devices.
    private func export() {
        let os = OSSourceConfig.all.first { $0.id == model.osFilter }?.name ?? "all"
        let term = model.mode.validated(model.query) ?? "results"
        let table: CSVExporter.Table
        let name: String
        if let part = shownPart {
            table = CSVExporter.table(for: StatusRows.make(part, devices: model.selectedDevices, statuses: model.status.statuses), part: part)
            name = "\(term)-\(part.title)"
        } else {
            table = CSVExporter.table(for: model.visibleRows)
            name = term
        }
        do {
            try CSVSavePanel.save(CSVExporter.data(for: table), suggestedName: CSVExporter.fileName(os: os, name: name))
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func revealSecrets(_ device: ManagedDevice) {
        guard let configuration = settings.authConfiguration else { return }
        model.secrets.begin(device, client: auth.graphClient(configuration.withSecrets))
    }

    private func rotateSecret(_ device: ManagedDevice, _ rotation: SecretRotation) {
        guard let configuration = settings.authConfiguration else { return }
        model.secrets.beginRotate(rotation, device: device, client: auth.graphClient(configuration.withSecrets))
    }

    private func read() {
        guard canRead, let configuration = settings.authConfiguration else { return }
        model.beginRead(client: auth.graphClient(configuration))
    }
}
