import UIKit
import Social
import UniformTypeIdentifiers

/// Porta share extension: received from Photos / Files / Safari etc.
///
/// For MVP, this extension does the minimum required by iOS: accept the
/// shared items, persist them to the app group's container, and hand off
/// to the main app via a custom URL scheme (porta://share?ids=...).
///
/// The main app then reads them out of the shared container and calls
/// `AppState.createShare(from:title:)`.
class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await importAndClose() }
    }

    private func importAndClose() async {
        guard let context = extensionContext,
              let items = context.inputItems as? [NSExtensionItem] else {
            close(); return
        }

        let fm = FileManager.default
        let group = "group.app.porta.ios"
        guard let shared = fm.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            close(); return
        }
        let inbox = shared.appendingPathComponent("inbox", isDirectory: true)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)

        var storedIDs: [String] = []
        for item in items {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if let id = await save(provider: provider, into: inbox) {
                    storedIDs.append(id)
                }
            }
        }

        // Open the host app with the imported file IDs.
        let joined = storedIDs.joined(separator: ",")
        if let url = URL(string: "porta://share?ids=\(joined)") {
            await openURL(url)
        }
        close()
    }

    private func save(provider: NSItemProvider, into inbox: URL) async -> String? {
        for type in [UTType.fileURL, .image, .movie, .item] {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                return await copyItem(provider: provider, type: type, into: inbox)
            }
        }
        return nil
    }

    private func copyItem(provider: NSItemProvider, type: UTType, into inbox: URL) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let id = UUID().uuidString
                let dest = inbox.appendingPathComponent(id + "_" + url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest.lastPathComponent)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func openURL(_ url: URL) async {
        // Extensions can't call UIApplication.shared.open directly. Walk the
        // responder chain until we find one that responds to `openURL:`.
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                _ = await app.open(url)
                return
            }
            responder = r.next
        }
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
