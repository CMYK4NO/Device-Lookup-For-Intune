import AppKit
import SwiftUI

/// Passwords and keys of the selected devices. Nothing is fetched until the user confirms a device's reveal.
struct SecretsPanelView: View {
    private struct PendingRotation: Identifiable {
        let device: ManagedDevice
        let rotation: SecretRotation
        var id: String { "\(device.id)/\(rotation.action)" }
    }

    private static let clipboardLifetime: TimeInterval = 60

    @ObservedObject var model: SecretsViewModel
    let devices: [ManagedDevice]
    let reveal: (ManagedDevice) -> Void
    let rotate: (ManagedDevice, SecretRotation) -> Void

    @State private var pending: ManagedDevice?
    @State private var pendingRotation: PendingRotation?
    @State private var shown: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Passwords and keys").font(.headline)
                // A second alert on the same view would not present, so this one hangs off the heading.
                .alert(
                    pendingRotation?.rotation.title ?? "",
                    isPresented: Binding(get: { pendingRotation != nil }, set: { if !$0 { pendingRotation = nil } }),
                    presenting: pendingRotation
                ) { item in
                    Button("Rotate", role: .destructive) { rotate(item.device, item.rotation) }
                    Button("Cancel", role: .cancel) {}
                } message: { item in
                    Text("\(item.rotation.consequence) Device: \(item.device.deviceName ?? item.device.id). The device must be online, and the action is recorded in the Intune audit log.")
                }
            ForEach(devices) { device in
                deviceRow(device)
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: model.reports) { _ in shown = [] }
        .alert(
            "Reveal passwords and keys?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { device in
            Button("Reveal") { reveal(device) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("This reads the secrets of \(device.deviceName ?? device.id). The access is recorded in the Entra and Intune audit logs.")
        }
    }

    private func deviceRow(_ device: ManagedDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.deviceName ?? device.id).fontWeight(.medium)
                Text(device.operatingSystem ?? "").foregroundStyle(.secondary)
                Spacer()
                if model.loading.contains(device.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.reports[device.id] == nil ? "Reveal…" : "Reload…") { pending = device }
                }
            }
            if let notice = model.notices[device.id] {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let report = model.reports[device.id] {
                ForEach(report.secrets) { secret in
                    secretRow(secret, device: device, key: "\(device.id)/\(secret.id)")
                }
                ForEach(report.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if report.secrets.isEmpty && report.notes.isEmpty {
                    Text("Nothing is stored for this device.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func secretRow(_ secret: DeviceSecret, device: ManagedDevice, key: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.title).font(.callout)
                Text([secret.detail, secret.date.map { $0.formatted(date: .abbreviated, time: .shortened) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                if shown.contains(key) {
                    Text(secret.value).textSelection(.enabled)
                } else {
                    Text(String(repeating: "•", count: 12))
                }
            }
            .font(.system(.callout, design: .monospaced))
            Button(shown.contains(key) ? "Hide" : "Show") {
                if shown.contains(key) { shown.remove(key) } else { shown.insert(key) }
            }
            Button("Copy") { copy(secret.value) }
            Button("Rotate") { pendingRotation = PendingRotation(device: device, rotation: secret.rotation) }
        }
        .padding(.leading, 12)
    }

    /// Puts the value on the pasteboard of this Mac only (not Universal Clipboard), marked as concealed so clipboard history
    /// apps skip it, and removes it again after a minute unless something else was copied since.
    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardLifetime) {
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }
}
