#if canImport(Network)
import Foundation

/// Renders a self-contained black/white/glass HTML landing page for a Porta
/// LAN share. Served by LANHost when the receiver opens the root URL in a
/// browser. Pure LAN — no backend dependency.
func renderLandingPage(manifest: LANHost.ShareManifest) -> String {
    let title = manifest.title ?? "Shared files"
    let rows = manifest.files.map { f -> String in
        let href = "/files/\(percentEncode(f.name))"
        let size = humanSize(f.size)
        return """
        <li class="row">
          <a class="name" href="\(esc(href))" download="\(esc(f.name))">\(esc(f.name))</a>
          <span class="size">\(esc(size))</span>
        </li>
        """
    }.joined(separator: "\n")

    let total = humanSize(manifest.files.reduce(0) { $0 + $1.size })
    let count = manifest.files.count
    let countText = "\(count) file\(count == 1 ? "" : "s")"

    return """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <title>\(esc(title)) — Porta</title>
      <style>\(css)</style>
    </head>
    <body>
      <main>
        <header>
          <h1>Porta</h1>
          <p class="sub">Direct LAN transfer. Files stream from the sender's phone.</p>
        </header>
        <section class="card">
          <h2>\(esc(title))</h2>
          <ul class="files">\(rows)</ul>
          <div class="meta"><span>\(countText)</span><span>\(esc(total))</span></div>
        </section>
        <p class="foot">Links stop working when the sender closes Porta.</p>
      </main>
    </body>
    </html>
    """
}

private let css = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  background: #000;
  color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Inter, sans-serif;
  min-height: 100vh;
  -webkit-font-smoothing: antialiased;
}
main { max-width: 560px; margin: 0 auto; padding: 32px 20px 64px; }
header h1 { font-size: 34px; font-weight: 700; margin: 0 0 4px; letter-spacing: -0.02em; }
header .sub { margin: 0 0 20px; color: rgba(255,255,255,0.6); font-size: 14px; }
.card {
  background: rgba(255,255,255,0.06);
  border: 1px solid rgba(255,255,255,0.10);
  border-radius: 20px;
  padding: 18px 20px;
  backdrop-filter: blur(22px) saturate(160%);
  -webkit-backdrop-filter: blur(22px) saturate(160%);
}
.card h2 { font-size: 18px; font-weight: 600; margin: 0 0 12px; }
.files { list-style: none; margin: 0; padding: 0; }
.row {
  display: flex; align-items: center; justify-content: space-between;
  padding: 12px 0; border-bottom: 1px solid rgba(255,255,255,0.08);
  gap: 12px;
}
.row:last-child { border-bottom: none; }
.name {
  color: #fff; text-decoration: none; font-size: 15px; font-weight: 500;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1 1 auto;
}
.name:hover { text-decoration: underline; text-underline-offset: 3px; }
.size {
  color: rgba(255,255,255,0.55); font-size: 13px; font-variant-numeric: tabular-nums;
  flex: 0 0 auto;
}
.meta {
  display: flex; justify-content: space-between; padding-top: 12px;
  margin-top: 4px; font-size: 12px; color: rgba(255,255,255,0.5);
  border-top: 1px solid rgba(255,255,255,0.08);
}
.foot { margin-top: 14px; font-size: 12px; color: rgba(255,255,255,0.4); text-align: center; }
"""

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&#39;")
}

private func percentEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
}

private func humanSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var n = Double(bytes) / 1024
    var u = 0
    while n >= 1024, u < units.count - 1 { n /= 1024; u += 1 }
    return String(format: n >= 10 ? "%.0f %@" : "%.1f %@", n, units[u])
}
#endif
