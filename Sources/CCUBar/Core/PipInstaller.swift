import Foundation

/// Runs `python3 -m pip install --user -r bridge/requirements.txt` so users don't
/// need to open a terminal if the bridge fails to start for missing packages.
enum PipInstaller {
    enum InstallError: Error {
        case pythonNotFound
        case bridgeNotFound
        case requirementsMissing
        case launchFailed(String)
        case exited(Int32)
    }

    /// Runs pip asynchronously. Returns on success, throws `InstallError` on failure.
    static func installRequirements() async throws {
        guard let python = BridgeRunner.findPython3() else {
            throw InstallError.pythonNotFound
        }
        guard let bridgeDir = BridgeRunner.locateBridgeDirectory() else {
            throw InstallError.bridgeNotFound
        }
        let requirements = bridgeDir.appendingPathComponent("requirements.txt")
        guard FileManager.default.fileExists(atPath: requirements.path) else {
            throw InstallError.requirementsMissing
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "pip", "install", "--user", "--disable-pip-version-check",
                       "-r", requirements.path]
        p.currentDirectoryURL = bridgeDir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            throw InstallError.launchFailed(String(describing: error))
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                p.waitUntilExit()
                continuation.resume()
            }
        }

        guard p.terminationStatus == 0 else {
            throw InstallError.exited(p.terminationStatus)
        }
    }
}
