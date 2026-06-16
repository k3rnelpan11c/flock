import Foundation

struct SessionPane: Codable {
    let type: String        // "claude", "shell", or "markdown"
    let workingDirectory: String?
    let customName: String?
    let sessionId: String?
    let draft: String?      // unsent shell command line, restored on next launch
}

/// Recursive node that mirrors SplitNode for serialization.
indirect enum SessionNode: Codable {
    case leaf(SessionPane)
    case split(direction: String, first: SessionNode, second: SessionNode, ratio: Double)

    // Manual Codable because recursive enums with associated values need it
    private enum CodingKeys: String, CodingKey {
        case kind, pane, direction, first, second, ratio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "leaf" {
            let pane = try c.decode(SessionPane.self, forKey: .pane)
            self = .leaf(pane)
        } else {
            let dir = try c.decode(String.self, forKey: .direction)
            let first = try c.decode(SessionNode.self, forKey: .first)
            let second = try c.decode(SessionNode.self, forKey: .second)
            let ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            self = .split(direction: dir, first: first, second: second, ratio: ratio)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try c.encode("leaf", forKey: .kind)
            try c.encode(pane, forKey: .pane)
        case .split(let direction, let first, let second, let ratio):
            try c.encode("split", forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
            try c.encode(ratio, forKey: .ratio)
        }
    }

    /// Collect all leaf panes in order.
    var allPanes: [SessionPane] {
        switch self {
        case .leaf(let pane): return [pane]
        case .split(_, let first, let second, _): return first.allPanes + second.allPanes
        }
    }
}

struct SessionLayout: Codable {
    // Flat list kept for backwards compatibility with old session.json files
    let panes: [SessionPane]?
    let activeIndex: Int
    // Tree-based tab layout (new)
    let tabs: [SessionNode]?
}

enum SessionRestore {
    private static var sessionURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Flock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    static func save(tabs: [SessionNode], activeIndex: Int) {
        let layout = SessionLayout(panes: nil, activeIndex: activeIndex, tabs: tabs)
        do {
            let data = try JSONEncoder().encode(layout)
            try data.write(to: sessionURL, options: .atomic)
        } catch {
            NSLog("[Flock] Session save failed: %@", error.localizedDescription)
        }
    }

    static func restore() -> SessionLayout? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: sessionURL)
            return try JSONDecoder().decode(SessionLayout.self, from: data)
        } catch {
            NSLog("[Flock] Session restore failed (possible corruption): %@", error.localizedDescription)
            return nil
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: sessionURL)
    }
}
