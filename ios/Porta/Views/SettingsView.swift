import SwiftUI
import Darwin

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL: String = ""
    @State private var testing = false

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        modeCard
                        serverCard
                        identityCard
                        presetsCard
                    }
                    .padding()
                }
            }
            .navigationTitle("Settings")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { save(); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear { draftURL = state.backendURLString }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transfer mode", systemImage: "square.stack.3d.up.fill")
                .font(.headline)
                .foregroundStyle(.white)
            Text("LAN mode needs no backend — your iPhone serves files directly to devices on the same Wi-Fi. Backend mode uses the reverse tunnel, so the link works off-network.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            Picker("Mode", selection: $state.preferredMode) {
                Text("LAN (no backend)").tag(TransferMode.lan)
                Text("Backend tunnel").tag(TransferMode.backend)
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Backend", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(.white)

            Text("Porta needs a signaling server to create share links. Point this at your dev server's LAN IP while testing on device.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            TextField("http://192.168.1.10:8080", text: $draftURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)

            HStack {
                connectionBadge
                Spacer()
                Button {
                    save()
                    Task { testing = true; await state.connect(); testing = false }
                } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) }
                        Text(testing ? "Testing…" : "Test connection")
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .foregroundStyle(.white)
            }
        }
        .padding(20)
        .glassCard()
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(connectionColor).frame(width: 8, height: 8)
            Text(connectionText).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var connectionColor: Color {
        switch state.connection {
        case .online:     return .white
        case .connecting: return .white.opacity(0.5)
        case .offline:    return .white.opacity(0.25)
        case .unknown:    return .white.opacity(0.35)
        }
    }

    private var connectionText: String {
        switch state.connection {
        case .online: "Connected"
        case .connecting: "Connecting…"
        case .offline(let reason): "Offline — \(reason)"
        case .unknown: "Not tested"
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Device identity", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.white)
            Text(state.deviceID ?? "Not registered yet — will register on first connect.")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.7))
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick presets", systemImage: "wand.and.stars")
                .font(.headline)
                .foregroundStyle(.white)
            Button { draftURL = "http://localhost:8080" } label: {
                presetRow("Simulator / local", "http://localhost:8080")
            }
            Button { draftURL = "http://\(suggestedLANIP()):8080" } label: {
                presetRow("This Mac on LAN", "http://\(suggestedLANIP()):8080")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func presetRow(_ title: String, _ url: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.white)
                Text(url).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 6)
    }

    private func save() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != state.backendURLString {
            state.backendURLString = trimmed
        }
    }

    private func suggestedLANIP() -> String {
        // Best-effort suggestion; user can edit freely if wrong.
        var address = "192.168.1.10"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ptr = cursor {
                let flags = Int32(ptr.pointee.ifa_flags)
                let family = ptr.pointee.ifa_addr.pointee.sa_family
                if (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING),
                   family == UInt8(AF_INET),
                   let name = String(validatingUTF8: ptr.pointee.ifa_name),
                   name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let found = String(cString: hostname)
                    if !found.isEmpty { address = found }
                }
                cursor = ptr.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
