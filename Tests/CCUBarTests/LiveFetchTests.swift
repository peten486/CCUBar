import XCTest
@testable import CCUBar

/// Integration test: spawns the real `claude` CLI via PTY and exercises the full fetch pipeline.
/// Skipped unless CCUBAR_LIVE=1 is set, because it is slow and depends on a logged-in CLI.
final class LiveFetchTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CCUBAR_LIVE"] == "1",
            "set CCUBAR_LIVE=1 to run this integration test"
        )
    }

    func testFetchUsageFromRealCLI() async throws {
        let portStr = ProcessInfo.processInfo.environment["CCUBAR_LIVE_PORT"] ?? ""
        guard let port = Int(portStr), (1...65535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)/api/usage") else {
            throw XCTSkip("set CCUBAR_LIVE_PORT=<port> to run this integration test")
        }
        let fetcher: UsageFetching = HttpUsageFetcher(endpoint: url)
        print("starting fetch at \(Date())")
        do {
            let snapshot = try await fetcher.fetch()
            print("""
            ----- live /usage snapshot -----
            session: \(snapshot.sessionPercent)%
            weekly: \(snapshot.weeklyPercent.map { "\($0)%" } ?? "nil")
            resetAt: \(snapshot.sessionResetAt.map { "\($0)" } ?? "nil")
            --------------------------------
            raw (\(snapshot.rawOutput.count) chars):
            \(snapshot.rawOutput)
            --------------------------------
            """)
            XCTAssertGreaterThanOrEqual(snapshot.sessionPercent, 0)
            XCTAssertLessThanOrEqual(snapshot.sessionPercent, 100)
        } catch let error as FetchError {
            switch error {
            case .parseFailure(let raw):
                print("""
                ----- parse failure (showing raw) -----
                \(raw)
                ---------------------------------------
                """)
                XCTFail("parse failure — inspect raw above to tune parser")
            case .claudeNotFound:
                throw XCTSkip("claude CLI not found")
            case .timeout:
                XCTFail("timed out fetching /usage — may need longer idle threshold")
            case .processFailed(let code):
                XCTFail("claude exited with code \(code)")
            }
        }
    }
}
