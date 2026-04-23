import AppKit
import Foundation

/// Opens GitHub's "new issue" page for the repository with a pre-filled body
/// containing the most recent bridge log entries and basic environment info.
enum IssueReporter {
    static let repoIssuesURL = "https://github.com/peten486/CCUBar/issues/new"

    /// Approximate URL-safe limit; GitHub accepts long URLs but very long ones
    /// risk being rejected by intermediaries. We cap the embedded log tail.
    private static let maxLogBytes = 6000

    static func openGitHubIssue() {
        let title = "[Report] CCU Bar issue"
        let body = composeBody()
        var components = URLComponents(string: repoIssuesURL)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func composeBody() -> String {
        var out = "## What happened?\n\n(describe the problem)\n\n"
        out += "## Environment\n\n"
        out += "- CCU Bar: \(appVersion())\n"
        out += "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "- Architecture: \(hostArchitecture())\n"
        out += "- Bridge dir: \(bridgeDirPath() ?? "(not found)")\n\n"
        out += "## Recent bridge log (tail)\n\n```\n"
        out += recentLogTail()
        out += "\n```\n"
        return out
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func hostArchitecture() -> String {
        var systeminfo = utsname()
        uname(&systeminfo)
        let mirror = Mirror(reflecting: systeminfo.machine)
        let bytes = mirror.children.compactMap { $0.value as? Int8 }
        let data = Data(bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .ascii) ?? "unknown"
    }

    private static func bridgeDirPath() -> String? {
        BridgeRunner.locateBridgeDirectory()?.path
    }

    private static func recentLogTail() -> String {
        let dataDir = BridgeRunner.bridgeDataDirectory()
        var blocks: [String] = []
        for name in ["app.log", "bridge_stderr.log"] {
            let url = dataDir.appendingPathComponent(name)
            if let tail = tail(of: url, bytes: maxLogBytes / 2) {
                blocks.append("— \(name) —\n\(tail)")
            }
        }
        return blocks.isEmpty ? "(no logs found in \(dataDir.path))" : blocks.joined(separator: "\n\n")
    }

    private static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
            try handle.seek(toOffset: start)
            let data = (try? handle.readToEnd()) ?? Data()
            if var s = String(data: data, encoding: .utf8) {
                if start > 0, let nl = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: nl)...])
                }
                return s
            }
        } catch {
            return "(failed to read log: \(error))"
        }
        return nil
    }
}
