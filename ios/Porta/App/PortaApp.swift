import SwiftUI

@main
struct PortaApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .task { await state.connect() }
                .onOpenURL { url in
                    DeepLinkRouter.handle(url: url, state: state)
                }
                .preferredColorScheme(.dark)
        }
    }
}

enum DeepLinkRouter {
    @MainActor
    static func handle(url: URL, state: AppState) {
        guard url.scheme == "porta",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch url.host {
        case "approve":
            if let sessionID = comps.queryItems?.first(where: { $0.name == "session" })?.value {
                state.pendingApprovals.append(.init(
                    sessionID: sessionID,
                    shareTitle: "Incoming request",
                    requesterIP: nil
                ))
            }
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var showingPicker = false
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            AmbientBackground()

            ScrollView {
                VStack(spacing: 20) {
                    HomeHeader(showSettings: { showingSettings = true })

                    if state.preferredMode == .backend && !state.connection.isOnline {
                        OfflineBanner(showSettings: { showingSettings = true })
                    }

                    PrimaryShareCard(onTap: { showingPicker = true })

                    if let active = state.activeShare {
                        ActiveShareCard(share: active)
                    }

                    if !state.pendingApprovals.isEmpty {
                        RequestsSection(approvals: state.pendingApprovals)
                    }

                    if !state.history.isEmpty {
                        HistorySection(entries: state.history)
                    }

                    Spacer(minLength: 40)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingPicker) {
            FilePickerView().preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().preferredColorScheme(.dark)
        }
        .alert("Something went wrong", isPresented: .init(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

private struct HomeHeader: View {
    @EnvironmentObject var state: AppState
    let showSettings: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Porta")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassCard(cornerRadius: 22)
            }
        }
        .padding(.top, 8)
    }

    private var dotColor: Color {
        if state.preferredMode == .lan { return .white }
        switch state.connection {
        case .online:     return .white
        case .connecting: return .white.opacity(0.5)
        case .offline:    return .white.opacity(0.25)
        case .unknown:    return .white.opacity(0.35)
        }
    }
    private var statusText: String {
        if state.preferredMode == .lan { return "LAN — ready to share" }
        switch state.connection {
        case .online:            return "Backend — ready to share"
        case .connecting:        return "Connecting to backend…"
        case .offline(let r):    return "Backend offline — \(r)"
        case .unknown:           return "Not connected"
        }
    }
}

private struct OfflineBanner: View {
    let showSettings: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text("Backend unreachable").font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text("Porta will use LAN mode until the backend is back.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Settings", action: showSettings)
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.14))
                .foregroundStyle(.white)
        }
        .padding(16)
        .glassCard()
    }
}

private struct PrimaryShareCard: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.15)).frame(width: 72, height: 72)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-20))
                        .offset(x: -2, y: 2)
                }
                Text("Share files")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Pick files, get a link, send it anywhere on your Wi-Fi. No backend, no account, no cloud. Transfer ends when you close Porta.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .glassCard(cornerRadius: 24)
        }
        .buttonStyle(.plain)
    }
}
