import AppKit

/// A known AI coding agent CLI that Flock can launch in a pane.
struct AgentCLI: Equatable {
    let id: String
    let displayName: String
    let command: String
    let launchArgs: String
    let colorHex: Int

    var color: NSColor { NSColor(hex: colorHex) }

    var launchCommand: String {
        launchArgs.isEmpty ? command : "\(command) \(launchArgs)"
    }

    static func == (lhs: AgentCLI, rhs: AgentCLI) -> Bool { lhs.id == rhs.id }

    static let known: [AgentCLI] = [
        AgentCLI(id: "codex",        displayName: "Codex",        command: "codex",        launchArgs: "", colorHex: 0x10A37F),
        AgentCLI(id: "gemini",       displayName: "Gemini",       command: "gemini",       launchArgs: "", colorHex: 0x4285F4),
        AgentCLI(id: "opencode",     displayName: "opencode",     command: "opencode",     launchArgs: "", colorHex: 0xF97316),
        AgentCLI(id: "aider",        displayName: "Aider",        command: "aider",        launchArgs: "", colorHex: 0x16A34A),
        AgentCLI(id: "goose",        displayName: "Goose",        command: "goose",        launchArgs: "", colorHex: 0x8B5CF6),
        AgentCLI(id: "amp",          displayName: "Amp",          command: "amp",          launchArgs: "", colorHex: 0xDC2626),
        AgentCLI(id: "copilot",      displayName: "Copilot",      command: "copilot",      launchArgs: "", colorHex: 0x6E40C9),
        AgentCLI(id: "cursor-agent", displayName: "Cursor Agent", command: "cursor-agent", launchArgs: "", colorHex: 0x64748B),
    ]

    static func byId(_ id: String) -> AgentCLI? {
        known.first { $0.id == id }
    }
}

/// Detects which agent CLIs are installed on this machine.
final class AgentCLIRegistry {
    static let shared = AgentCLIRegistry()
    static let didChange = Notification.Name("FlockAgentCLIRegistryDidChange")

    private(set) var installed: [AgentCLI] = []

    /// Scans for installed CLIs on a background queue and posts didChange on main.
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let dirs = Self.searchDirectories()
            let fm = FileManager.default
            let found = AgentCLI.known.filter { cli in
                dirs.contains { dir in
                    fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(cli.command))
                }
            }
            DispatchQueue.main.async {
                guard let self, found != self.installed else { return }
                self.installed = found
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }

    /// GUI apps inherit a minimal PATH, so ask a login shell for the real one,
    /// then add common install locations as a fallback.
    private static func searchDirectories() -> [String] {
        var dirs: [String] = []

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        if (try? proc.run()) != nil {
            let timeout = DispatchTime.now() + 5
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                done.signal()
            }
            if done.wait(timeout: timeout) == .timedOut {
                proc.terminate()
            } else if let data = try? pipe.fileHandleForReading.readToEnd(),
                      let path = String(data: data, encoding: .utf8) {
                dirs += path.split(separator: ":").map(String.init)
            }
        }

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs += envPath.split(separator: ":").map(String.init)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
        ]

        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }
}
