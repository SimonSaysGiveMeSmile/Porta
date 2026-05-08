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

                    if !state.connection.isOnline {
                        OfflineBanner(showSettings: { showingSettings = true })
                    }

                    PrimaryShareCard(onTap: { showingPicker = true })

                    if let active = state.activeShare {
                        ActiveShareCard(share: active)
                    }

                    if !state.pendingApprovals.isEmpty {
                        RequestsSection(approvals: state.pendingApprovals)
                    }

                    if !state.recentShares.isEmpty {
                        RecentSection(shares: state.recentShares)
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
        switch state.connection {
        case .online: .green
        case .connecting: .yellow
        case .offline: .orange
        case .unknown: .gray
        }
    }
    private var statusText: String {
        switch state.connection {
        case .online: "Ready to share"
        case .connecting: "Connecting to server…"
        case .offline(let r): "Offline — \(r)"
        case .unknown: "Not connected"
        }
    }
}

private struct OfflineBanner: View {
    let showSettings: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Server unreachable").font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text("Open Settings to point Porta at your dev server.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Settings", action: showSettings)
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
        }
        .padding(16)
        .glassCard(tint: .orange)
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
                Text("Pick files, get a link, send it anywhere. Transfer is peer-to-peer and ends when you close Porta.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .glassCard(cornerRadius: 24, tint: .cyan)
        }
        .buttonStyle(.plain)
    }
}
