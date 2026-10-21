import SwiftUI
import CoreImage.CIFilterBuiltins

struct E2EELockBadge: View {
    let conversationId: String
    @ObservedObject private var status = E2EEStatusStore.shared
    var body: some View {
        if status.isEnabled(conversationId) {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct E2EELinkedDevicesView: View {
    @State private var devices: [E2EEDeviceSummary] = []
    @State private var loading = true
    private let thisDevice = E2EEService.shared.deviceId

    var body: some View {
        List {
            ForEach(devices) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name.isEmpty ? "Device" : d.name) + Text(d.deviceId == thisDevice ? "  (this device)" : "").foregroundColor(.secondary)
                    Text("Added \(d.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .swipeActions {
                    if d.deviceId != thisDevice {
                        Button("Remove", role: .destructive) { remove(d) }
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Linked devices")
        .task { await load() }
    }

    private func load() async {
        devices = (try? await NetworkService.shared.e2eeListMyDevices()) ?? []
        loading = false
    }

    private func remove(_ d: E2EEDeviceSummary) {
        Task {
            try? await NetworkService.shared.e2eeRevokeDevice(d.deviceId)
            await load()
        }
    }
}

struct E2EESafetyNumberView: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @State private var members: [String] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Compare a person's safety number with theirs, in person or over another channel you trust. If the numbers match, nobody is intercepting your messages.")) {
                    ForEach(members, id: \.self) { id in
                        NavigationLink {
                            E2EESafetyNumberDetailView(conversationId: conversationId, userId: id, name: Self.name(for: id))
                        } label: {
                            Text(Self.name(for: id))
                        }
                    }
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if members.isEmpty { Text("Nobody here has set up encryption yet.").foregroundStyle(.secondary).padding() }
            }
            .navigationTitle("Safety numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                members = await E2EEService.shared.safetyMembers(conversationId: conversationId)
                loading = false
            }
        }
    }

    static func name(for userId: String) -> String {
        ChatParticipantDirectory.shared.displayName(for: userId) ?? "Member"
    }
}

struct E2EESafetyNumberDetailView: View {
    let conversationId: String
    let userId: String
    let name: String

    @State private var info: E2EEService.SafetyInfo?
    @State private var failed = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let info {
                    if info.keyMismatch {
                        banner("A device's key doesn't match the one this phone saved. Don't trust this chat until you've compared numbers with \(name).", color: .red)
                    } else if info.changedSinceVerified {
                        banner("Your safety number with \(name) has changed since you verified it. They may have a new device or reinstalled the app. Compare it again.", color: .orange)
                    }

                    if let qr = Self.qrImage(info.qrPayload) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 190, height: 190)
                            .padding(10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                    }

                    VStack(spacing: 8) {
                        ForEach(Array(E2EESafetyNumber.grouped(info.number).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 14) {
                                ForEach(row, id: \.self) { Text($0) }
                            }
                        }
                    }
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Safety number: " + info.number.map(String.init).joined(separator: " "))

                    Text("To verify end-to-end encryption with \(name), compare this number with the one on their phone. It covers \(info.deviceCount) of their \(info.deviceCount == 1 ? "device" : "devices") and all of yours.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = info.number
                            copied = true
                        } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.bordered)
                        ShareLink(item: info.number) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }

                    Button {
                        E2EEService.shared.setVerified(userId: userId, number: info.isVerified ? nil : info.number)
                        Task { await load() }
                    } label: {
                        Label(info.isVerified ? "Verified · tap to clear" : "Mark as verified",
                              systemImage: info.isVerified ? "checkmark.shield.fill" : "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(info.isVerified ? .green : .accentColor)
                } else if failed {
                    Text("Couldn't load the safety number. \(name) may not have set up encryption yet.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do { info = try await E2EEService.shared.safetyInfo(conversationId: conversationId, otherUserId: userId) }
        catch { failed = true }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(.primary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
