import Foundation

/// A single entry in the user's share history. Covers both LAN shares
/// (no backend) and backend-hosted shares so the UI can show one unified
/// timeline.
public struct ShareHistoryEntry: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable, Hashable {
        case lan
        case backend
    }

    public let id: UUID
    public let kind: Kind
    public let title: String?
    public let shareURL: String
    public let fileNames: [String]
    public let totalBytes: Int64
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String?,
        shareURL: String,
        fileNames: [String],
        totalBytes: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.shareURL = shareURL
        self.fileNames = fileNames
        self.totalBytes = totalBytes
        self.createdAt = createdAt
    }
}

/// Persists share history to UserDefaults. Capped at `maxEntries` so the
/// store doesn't grow unbounded — this is an activity log, not an archive.
public final class ShareHistoryStore {
    private let defaults: UserDefaults
    private let key: String
    private let maxEntries: Int

    public init(
        defaults: UserDefaults = .standard,
        key: String = "porta.shareHistory.v1",
        maxEntries: Int = 50
    ) {
        self.defaults = defaults
        self.key = key
        self.maxEntries = maxEntries
    }

    public func load() -> [ShareHistoryEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ShareHistoryEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [ShareHistoryEntry]) {
        let capped = Array(entries.prefix(maxEntries))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        defaults.set(data, forKey: key)
    }

    public func prepend(_ entry: ShareHistoryEntry) -> [ShareHistoryEntry] {
        var all = load()
        all.removeAll { $0.id == entry.id }
        all.insert(entry, at: 0)
        save(all)
        return all
    }

    public func remove(id: UUID) -> [ShareHistoryEntry] {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
        return all
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
