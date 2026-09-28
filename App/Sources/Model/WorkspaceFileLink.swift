import Foundation

enum WorkspaceFileLink {
    /// Relative Markdown destinations belong to the conversation working directory,
    /// never to the bundled HTML renderer. No filesystem or network access is performed.
    static func resolve(_ raw: String, cwd: String, home: String = NSHomeDirectory()) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("#"), !text.contains("\0") else { return nil }
        if let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            guard url.host != nil else { return nil }
            return url
        }
        let local = text.replacingOccurrences(of: #":\d+(?::\d+)?(?=(?:[#?].*)?$)"#, with: "", options: .regularExpression)
        guard let components = URLComponents(string: local) else { return nil }
        if let scheme = components.scheme {
            guard scheme == "file", components.host == nil || components.host == "" || components.host == "localhost" else { return nil }
        }
        var path = components.path
        if path == "~" { path = home }
        else if path.hasPrefix("~/") { path = home + String(path.dropFirst()) }
        guard !path.isEmpty else { return nil }
        if !path.hasPrefix("/") { path = (cwd as NSString).appendingPathComponent(path) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
