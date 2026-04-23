import Foundation

/// Spawns and manages the bundled `bridge/claude_usage_scraper.py` Python process.
/// The bridge runs as a child of CCU Bar and is terminated when the app quits,
/// so the user never has to open a terminal.
@MainActor
final class BridgeRunner {
    enum StartError: Error, Equatable {
        case bridgeDirectoryNotFound
        case scriptNotFound(String)
        case pythonNotFound
        case launchFailed(String)
    }

    private(set) var runningPort: Int?
    private var process: Process?

    init() {
        // Reap any stale bundled-bridge processes from a previous run that was
        // killed abruptly (crash, kill -9, logout without quitting cleanly).
        Self.killOrphanedBridges()
    }

    /// Locate the bridge directory in one of three places, in order:
    /// 1. Inside the .app bundle (`Contents/Resources/bridge`) for release builds
    /// 2. `$CWD/bridge` when the executable is launched from the repo root
    /// 3. A sibling `bridge` folder next to the executable (common when `swift run`)
    nonisolated static func locateBridgeDirectory() -> URL? {
        let fm = FileManager.default

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("bridge", isDirectory: true)
            if fm.fileExists(atPath: bundled.appendingPathComponent("claude_usage_scraper.py").path) {
                return bundled
            }
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdCandidate = cwd.appendingPathComponent("bridge", isDirectory: true)
        if fm.fileExists(atPath: cwdCandidate.appendingPathComponent("claude_usage_scraper.py").path) {
            return cwdCandidate
        }

        if let execURL = Bundle.main.executableURL {
            let sibling = execURL.deletingLastPathComponent().appendingPathComponent("bridge", isDirectory: true)
            if fm.fileExists(atPath: sibling.appendingPathComponent("claude_usage_scraper.py").path) {
                return sibling
            }
        }

        return nil
    }

    /// Writable per-user directory where the bridge stores its log files and
    /// `token.ini`. Needed because `Contents/Resources/bridge/` is read-only
    /// when the app lives in `/Applications/`, which would crash the Python
    /// process on its first write attempt.
    nonisolated static func bridgeDataDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("CCUBar", isDirectory: true)
            .appendingPathComponent("bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pick the first python3 on the system that actually has the bridge's dependencies
    /// installed. We prefer Homebrew over Apple's bundled Python because third-party
    /// packages almost always live there, and `/usr/bin/python3` on stock macOS lacks
    /// `flask`, `browser_cookie3`, `curl_cffi`, etc.
    ///
    /// Probing Python subprocesses is ~1s worst case, so the result is cached after
    /// the first call. **Must NOT be called from the main thread** (it blocks).
    nonisolated static func findPython3() -> String? {
        pythonCacheLock.lock()
        if let cached = cachedPythonPath { pythonCacheLock.unlock(); return cached }
        pythonCacheLock.unlock()

        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/python3",   // Apple Silicon Homebrew
            "/usr/local/bin/python3",      // Intel Homebrew / pyenv
            "/usr/bin/python3"             // Apple-bundled fallback
        ]
        let probe = "import flask, browser_cookie3, curl_cffi, cryptography, certifi"
        var resolved: String?
        for path in candidates where fm.isExecutableFile(atPath: path) {
            if runImportProbe(python: path, code: probe) {
                resolved = path
                break
            }
        }
        if resolved == nil {
            resolved = candidates.first { fm.isExecutableFile(atPath: $0) }
        }

        pythonCacheLock.lock()
        cachedPythonPath = resolved
        pythonCacheLock.unlock()
        return resolved
    }

    nonisolated(unsafe) private static var cachedPythonPath: String?
    nonisolated private static let pythonCacheLock = NSLock()

    nonisolated private static func runImportProbe(python: String, code: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", code]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Start (or restart) the bridge on the given port. Idempotent — if the
    /// bridge is already running on this port it's left alone. If an external
    /// process is already listening on the port, we leave it alone and just
    /// point our polling at it.
    /// Start (or restart) the bridge on the given port.
    ///
    /// Runs all subprocess probing + spawning on a detached task so the caller
    /// (onboarding / AppDelegate) never blocks the main thread. Idempotent: no
    /// work if we're already running on `port`, or if an external process has
    /// the port.
    func start(port: Int) async throws {
        let dataDir = Self.bridgeDataDirectory()
        Self.diag(dataDir: dataDir, "start(port=\(port)) called")

        guard (1...65535).contains(port) else {
            Self.diag(dataDir: dataDir, "invalid port \(port)")
            throw StartError.launchFailed("invalid port")
        }

        if let existing = process, existing.isRunning, runningPort == port {
            Self.diag(dataDir: dataDir, "already running on \(port) — noop")
            return
        }

        if Self.isPortListening(port: port) {
            Self.diag(dataDir: dataDir, "port \(port) already held by external process — noop")
            await stopAsync()
            return
        }

        await stopAsync()

        // All the heavy lifting (python probes + Process.run) on a background actor.
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.spawnBridge(port: port, dataDir: dataDir)
        }.value

        self.process = result
        self.runningPort = port
        Self.diag(dataDir: dataDir, "spawned pid=\(result.processIdentifier) on port \(port)")
    }

    /// All subprocess work happens here, never on the main thread.
    nonisolated private static func spawnBridge(port: Int, dataDir: URL) throws -> Process {
        guard let bridgeDir = locateBridgeDirectory() else {
            diag(dataDir: dataDir, "bridge directory not found")
            throw StartError.bridgeDirectoryNotFound
        }
        diag(dataDir: dataDir, "bridge dir: \(bridgeDir.path)")

        let script = bridgeDir.appendingPathComponent("claude_usage_scraper.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            diag(dataDir: dataDir, "script missing: \(script.path)")
            throw StartError.scriptNotFound(script.path)
        }

        guard let python = findPython3() else {
            diag(dataDir: dataDir, "no python3 found")
            throw StartError.pythonNotFound
        }
        diag(dataDir: dataDir, "python: \(python)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path, "--server", "--port", String(port)]
        p.currentDirectoryURL = dataDir
        p.standardOutput = FileHandle.nullDevice

        let stderrURL = dataDir.appendingPathComponent("bridge_stderr.log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        if let stderrHandle = try? FileHandle(forWritingTo: stderrURL) {
            try? stderrHandle.seekToEnd()
            p.standardError = stderrHandle
        } else {
            p.standardError = FileHandle.nullDevice
        }

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["CCUBAR_BRIDGE_DATA"] = dataDir.path
        p.environment = env

        do {
            try p.run()
        } catch {
            diag(dataDir: dataDir, "Process.run failed: \(error)")
            throw StartError.launchFailed(String(describing: error))
        }
        return p
    }

    /// Non-blocking version of `stop()` — never sleeps on the main thread.
    func stopAsync() async {
        guard let p = process, p.isRunning else {
            process = nil
            runningPort = nil
            return
        }
        let pid = p.processIdentifier
        process = nil
        runningPort = nil

        await Task.detached(priority: .utility) {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }.value
    }

    nonisolated private static func diag(dataDir: URL, _ message: String) {
        let line = "[\(isoTimestamp())] \(message)\n"
        NSLog("[CCUBar] \(message)")
        let url = dataDir.appendingPathComponent("runner_diag.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    nonisolated private static func isoTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            // Give it up to 500 ms to exit gracefully; then SIGKILL.
            let deadline = Date().addingTimeInterval(0.5)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
        process = nil
        runningPort = nil
    }

    var isRunning: Bool {
        guard let p = process else { return false }
        return p.isRunning
    }

    /// Returns true if a process is already listening on `127.0.0.1:<port>`.
    /// Used to avoid double-spawn when the user has an external bridge running,
    /// and to pick a free port at first launch.
    nonisolated static func isPortListening(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Picks a random port in the private/ephemeral range that isn't currently held
    /// by another process. Falls back to a value in range even if every probe is
    /// inconclusive, so callers always receive a usable port.
    nonisolated static func pickFreePort(in range: ClosedRange<Int> = 49152...65500, attempts: Int = 40) -> Int {
        for _ in 0..<attempts {
            let candidate = Int.random(in: range)
            if !isPortListening(port: candidate) {
                return candidate
            }
        }
        return Int.random(in: range)
    }

    /// Find and kill any python processes running our bundled `claude_usage_scraper.py`.
    /// Called at launch so a crash / force-quit from a previous session doesn't leave
    /// an orphan listening on the old port.
    ///
    /// Runs on a detached background queue with a hard 2s timeout so a slow `ps`
    /// can never hold up app startup. Drains the stdout pipe as the child writes
    /// to avoid the classic waitUntilExit + pipe-buffer-fill deadlock.
    nonisolated private static func killOrphanedBridges() {
        guard let bridgeDir = locateBridgeDirectory() else { return }
        let scriptPath = bridgeDir.appendingPathComponent("claude_usage_scraper.py").path
        let ourPid = ProcessInfo.processInfo.processIdentifier

        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axo", "pid=,command="]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            do { try p.run() } catch { return }

            // Read stdout concurrently so the 64 KB pipe buffer never fills up.
            let readHandle = pipe.fileHandleForReading
            let data = readHandle.readDataToEndOfFile()

            // Bound the wait so a stuck `ps` (unlikely but possible) can't hang us.
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if p.isRunning {
                p.terminate()
            }

            guard let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") else { return }
            var killed: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(scriptPath) else { continue }
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let first = parts.first, let pid = Int32(first), pid != ourPid else { continue }
                kill(pid, SIGTERM)
                killed.append("\(pid)")
            }
            if !killed.isEmpty {
                NSLog("[CCUBar] reaped orphan bridge(s): \(killed.joined(separator: ", "))")
            }
        }
    }
}
