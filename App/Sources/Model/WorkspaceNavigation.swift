import Foundation
import Observation

enum WorkspaceRoute: String, CaseIterable, Codable, Sendable {
    case home, history, library, images, apps, settings
    var title: String {
        switch self {
        case .home: return "对话"
        case .history: return "历史"
        case .library: return "资料库"
        case .images: return "图片"
        case .apps: return "应用"
        case .settings: return "设置"
        }
    }
}

/// Navigation belongs to the window, independently of native Claude/Codex session identity.
@MainActor @Observable final class WorkspaceNavigation {
    struct Location: Equatable, Sendable {
        var route: WorkspaceRoute
        var threadID: String?
    }
    private(set) var locations: [Location]
    private(set) var index = 0
    var searchPresented = false
    var inspectorVisible: Bool
    var route: WorkspaceRoute { location.route }
    var location: Location { locations[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < locations.count }

    init(route: WorkspaceRoute = .home, threadID: String? = nil, inspectorVisible: Bool = true) {
        locations = [Location(route: route, threadID: threadID)]
        self.inspectorVisible = inspectorVisible
    }
    func visit(_ route: WorkspaceRoute, threadID: String? = nil) {
        let next = Location(route: route, threadID: route == .home ? threadID : nil)
        guard next != location else { return }
        locations = Array(locations.prefix(index + 1))
        locations.append(next)
        if locations.count > 100 { locations.removeFirst() }
        index = locations.count - 1
    }
    func seed(threadID: String?) {
        guard locations.count == 1, location.route == .home, location.threadID == nil else { return }
        locations[0].threadID = threadID
    }
    func replaceThreadID(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        locations = locations.map { location in
            var updated = location
            if updated.threadID == oldID { updated.threadID = newID }
            return updated
        }
    }
    func back() { if canGoBack { index -= 1 } }
    func forward() { if canGoForward { index += 1 } }
}
