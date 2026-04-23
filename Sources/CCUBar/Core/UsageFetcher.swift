import Foundation

protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageSnapshot
}

/// Reads the user-configured bridge port at fetch time and proxies the call to
/// `HttpUsageFetcher`. Kept as a thin wrapper so the port change takes effect
/// immediately after the user edits Settings.
struct BridgeFetcher: UsageFetching {
    let settingsProvider: @Sendable () -> Settings

    func fetch() async throws -> UsageSnapshot {
        let port = settingsProvider().bridgePort
        guard port > 0, port <= 65535,
              let url = URL(string: "http://127.0.0.1:\(port)/api/usage")
        else {
            throw FetchError.claudeNotFound
        }
        return try await HttpUsageFetcher(endpoint: url).fetch()
    }
}
