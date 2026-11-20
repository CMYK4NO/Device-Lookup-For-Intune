import SwiftUI

/// The tabs of the device status: compliance, configuration and managed apps show their table below; attributes show their list here.
enum StatusTab: String, CaseIterable, Identifiable {
    case compliance = "Compliance"
    case configuration = "Configuration"
    case apps = "Managed apps"
    case attributes = "Attributes"
    var id: Self { self }

    /// The part of the status this tab shows. The attributes tab has none.
    var part: StatusPart? {
        switch self {
        case .compliance: return .compliance
        case .configuration: return .configuration
        case .apps: return .apps
        case .attributes: return nil
        }
    }
}

/// Tab bar of the selected devices' status, with what could not be read. Opening a tab reads its part.
struct DeviceStatusPanelView<Attributes: View>: View {
    private struct LoadKey: Hashable {
        let tab: StatusTab
        let deviceIDs: [String]
    }

    @ObservedObject var model: DeviceStatusViewModel
    @Binding var tab: StatusTab
    let devices: [ManagedDevice]
    let load: (StatusPart) -> Void
    let attributes: Attributes

    init(model: DeviceStatusViewModel, tab: Binding<StatusTab>, devices: [ManagedDevice], load: @escaping (StatusPart) -> Void, @ViewBuilder attributes: () -> Attributes) {
        _model = ObservedObject(wrappedValue: model)
        _tab = tab
        self.devices = devices
        self.load = load
        self.attributes = attributes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device status").font(.headline)
                Picker("", selection: $tab) {
                    ForEach(StatusTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if tab == .attributes {
                attributes
            } else {
                notes
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // Opening a tab reads its part, after a short pause so a quick change of selection or tab costs nothing.
        .task(id: LoadKey(tab: tab, deviceIDs: devices.map(\.id))) {
            guard let part = tab.part else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            load(part)
        }
    }

    /// Parts that could not be read, per device, with a retry.
    private var notes: some View {
        ForEach(devices) { device in
            ForEach((model.statuses[device.id]?.notes ?? []).filter { $0.hasPrefix(tab.rawValue) }, id: \.self) { note in
                HStack(spacing: 8) {
                    Text("\(device.deviceName ?? device.id): \(note)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    if let part = tab.part, !model.isLoading {
                        Button("Retry") { load(part) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}
