import SwiftUI

struct AttributeResultsView: View {
    let config: OSSourceConfig
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var auth: AuthService
    @StateObject private var model: AttributeResultsViewModel
    @State private var selection: String?
    @State private var reloadToken = 0
    @State private var exportError: String?

    init(config: OSSourceConfig, script: ScriptSummary) {
        self.config = config
        _model = StateObject(wrappedValue: AttributeResultsViewModel(config: config, script: script, inventorySource: .shared, cache: .shared))
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                content
            }
            .frame(minHeight: 200)
            inspector
                .frame(minHeight: 120, idealHeight: 180)
        }
        .task(id: reloadToken) {
            guard let configuration = settings.authConfiguration else { return }
            ResultsWarmup.shared.cancel()
            RecentItems().record(sourceID: config.id, itemID: model.script.id)
            await model.load(client: auth.graphClient(config.authConfiguration(configuration)), force: reloadToken > 0)
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Table writes its sort order while SwiftUI is updating views; publishing that directly triggers a runtime warning.
    private var sortOrder: Binding<[KeyPathComparator<AttributeRow>]> {
        Binding(
            get: { model.sortOrder },
            set: { newValue in
                guard newValue != model.sortOrder else { return }
                DispatchQueue.main.async { model.sortOrder = newValue }
            }
        )
    }

    private func export(_ rows: [AttributeRow]) {
        do {
            try CSVSavePanel.save(
                CSVExporter.data(for: CSVExporter.table(for: rows, includesValue: config.showsValue)),
                suggestedName: CSVExporter.fileName(os: config.name, name: model.script.title)
            )
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.script.title).font(.headline).textSelection(.enabled)
                    Text(model.script.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    // Rows already on screen come from an earlier read that is being refreshed.
                    Text(model.rows.isEmpty ? "Loading… \(model.loadedCount) devices" : "Refreshing… \(model.loadedCount) devices")
                } else if model.isFiltering {
                    ProgressView().controlSize(.small)
                    Text("Sorting…")
                }
                if model.errorMessage == nil, !model.rows.isEmpty || !model.isLoading {
                    Text("\(model.filteredRows.count) of \(model.rows.count) devices")
                }
                if let loadedAt = model.loadedAt {
                    Text("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                }
            }
            controls
        }
        .padding(12)
    }

    /// Run-state filter, search box, reload and export, in that order.
    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Run state", selection: $model.runStateFilter) {
                Text("All run states").tag(String?.none)
                ForEach(model.runStates, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Filter devices, users, values", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
            Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
                .disabled(model.isLoading)
            Menu {
                Button("Export CSV (all rows)") { export(model.rows) }
                Button("Export filtered view") { export(model.filteredRows) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(model.isLoading || model.rows.isEmpty)
        }
    }

    @ViewBuilder private var content: some View {
        if let message = model.errorMessage {
            Text(message).foregroundStyle(.red).textSelection(.enabled).padding()
            Spacer()
        } else if !model.isLoading && model.rows.isEmpty {
            Text("No device has reported a result for this attribute yet.").foregroundStyle(.secondary).padding()
            Spacer()
        } else {
            table
        }
    }

    /// Conditional columns need macOS 14.4, so the table without the Value column is written out separately.
    @ViewBuilder private var table: some View {
        if config.showsValue {
            copyable(Table(model.filteredRows, selection: $selection, sortOrder: sortOrder) {
                TableColumn("Device", value: \.device) { Text($0.device) }
                TableColumn("User (UPN)", value: \.user) { Text($0.user) }
                TableColumn("Serial", value: \.serial) { Text($0.serial) }
                TableColumn("OS version", value: \.osVersion) { Text($0.osVersion) }
                TableColumn("Value", value: \.value) { ValueCell(value: $0.value) }
                    .width(min: 120, ideal: valueWidth)
                TableColumn("Run state", value: \.runState) { Text($0.runState) }
                TableColumn("Last updated", value: \.lastUpdatedSort) { row in
                    Text(row.lastUpdated.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                }
            })
            .id(model.tableVersion)
        } else {
            copyable(Table(model.filteredRows, selection: $selection, sortOrder: sortOrder) {
                TableColumn("Device", value: \.device) { Text($0.device) }
                TableColumn("User (UPN)", value: \.user) { Text($0.user) }
                TableColumn("Serial", value: \.serial) { Text($0.serial) }
                TableColumn("OS version", value: \.osVersion) { Text($0.osVersion) }
                TableColumn("Run state", value: \.runState) { Text($0.runState) }
                TableColumn("Last updated", value: \.lastUpdatedSort) { row in
                    Text(row.lastUpdated.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                }
            })
            .id(model.tableVersion)
        }
    }

    private var valueWidth: CGFloat {
        ValueCell.idealWidth(for: model.rows.lazy.map(\.value))
    }

    /// Right-click a row to copy one column or the whole row; ⌘C copies the selected row. Cells stay plain text, because
    /// selectable text in a cell takes the click that selects the row.
    private func copyable(_ table: some View) -> some View {
        table
            .contextMenu(forSelectionType: String.self) { ids in
                CopyMenu(rows: model.filteredRows.filter { ids.contains($0.id) }.map { $0.copyFields(includesValue: config.showsValue) })
            }
            .onCopyCommand {
                TableText.items(for: model.rows.filter { $0.id == selection }.map { $0.copyFields(includesValue: config.showsValue) })
            }
    }

    @ViewBuilder private var inspector: some View {
        if let row = model.rows.first(where: { $0.id == selection }) {
            RowInspectorView(row: row, valueField: config.valueField, operatingSystem: model.operatingSystem(of: row))
        } else {
            Text("Select a row to inspect its raw JSON.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
