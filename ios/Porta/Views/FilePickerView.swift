import SwiftUI
import PortaCore
import UniformTypeIdentifiers

struct FilePickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pickedURLs: [URL] = []
    @State private var title = ""
    @State private var showPicker = false
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        titleCard
                        filesCard
                    }
                    .padding()
                }
            }
            .navigationTitle("New share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        creating = true
                        Task {
                            await state.createShare(from: pickedURLs, title: title.isEmpty ? nil : title)
                            creating = false
                            dismiss()
                        }
                    } label: {
                        if creating { ProgressView().tint(.white) }
                        else { Text("Create").fontWeight(.semibold) }
                    }
                    .disabled(pickedURLs.isEmpty || creating)
                    .foregroundStyle(.white)
                }
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result { pickedURLs = urls }
            }
        }
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title").font(.caption).foregroundStyle(.white.opacity(0.6))
            TextField("Meeting notes, RAW photos…", text: $title)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Files").font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    showPicker = true
                } label: {
                    Label(pickedURLs.isEmpty ? "Choose" : "Add more", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            if pickedURLs.isEmpty {
                Button { showPicker = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.up.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("Tap to choose files")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 8) {
                    ForEach(pickedURLs, id: \.self) { url in
                        FileRow(url: url) {
                            pickedURLs.removeAll { $0 == url }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct FileRow: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let size = fileSize { Text(size).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var iconName: String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif": "photo.fill"
        case "mov", "mp4", "m4v": "film.fill"
        case "pdf": "doc.richtext.fill"
        case "zip", "tar", "gz": "doc.zipper"
        default: "doc.fill"
        }
    }

    private var fileSize: String? {
        guard let bytes = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ActiveShareCard: View {
    let share: ActiveShare
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(.white).frame(width: 8, height: 8)
                Text("Active share").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(share.kind == .lan ? "LAN" : "Backend")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            Text(share.title ?? "Untitled")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                Text(share.shareURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    UIPasteboard.general.string = share.shareURL
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.14), in: Capsule())
                }
            }
            .padding(10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(share.kind == .lan
                ? "Open this URL on any device on the same Wi-Fi. Closing Porta stops the transfer."
                : "Share this link anywhere. Closing Porta ends the session.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct RequestsSection: View {
    let approvals: [PendingApproval]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Requests", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.white)
            ForEach(approvals) { ApprovalCard(approval: $0) }
        }
    }
}

struct ApprovalCard: View {
    @EnvironmentObject var state: AppState
    let approval: PendingApproval

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill.questionmark")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(approval.shareTitle).font(.callout.weight(.semibold)).foregroundStyle(.white)
                if let ip = approval.requesterIP {
                    Text(ip).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Button { Task { await state.reject(approval) } } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.white.opacity(0.12), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
            }
            Button { Task { await state.approve(approval) } } label: {
                Image(systemName: "checkmark").font(.footnote.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(10)
                    .background(.white, in: Circle())
            }
        }
        .padding(16)
        .glassCard()
    }
}

struct HistorySection: View {
    @EnvironmentObject var state: AppState
    let entries: [ShareHistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("History", systemImage: "clock.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button("Clear") { state.clearHistory() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            VStack(spacing: 8) {
                ForEach(entries) { HistoryRow(entry: $0) }
            }
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var state: AppState
    let entry: ShareHistoryEntry
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .lan ? "wifi" : "link")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? "Share")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(entry.kind == .lan ? "LAN" : "Backend")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("·").foregroundStyle(.white.opacity(0.35))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(entry.shareURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = entry.shareURL
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(8)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
        .contextMenu {
            Button(role: .destructive) {
                state.deleteHistoryEntry(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var subtitle: String {
        let count = entry.fileNames.count
        let filesText = "\(count) file\(count == 1 ? "" : "s")"
        let size = ByteCountFormatter.string(fromByteCount: entry.totalBytes, countStyle: .file)
        let when = Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date())
        return "\(filesText) · \(size) · \(when)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
