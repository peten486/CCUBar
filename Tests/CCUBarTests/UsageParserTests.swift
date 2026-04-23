import XCTest
@testable import CCUBar

final class UsageParserTests: XCTestCase {
    private let parser = UsageParser()

    func testParsesProFixture() throws {
        let text = try loadFixture("usage_pro")
        let snap = try parser.parse(text, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snap.session.percent, 29.0, accuracy: 0.001)
        XCTAssertNil(snap.weekly)
        XCTAssertNotNil(snap.session.resetAt)
    }

    func testParsesMax5Fixture() throws {
        let text = try loadFixture("usage_max5")
        let snap = try parser.parse(text, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snap.session.percent, 62.0, accuracy: 0.001)
        XCTAssertEqual(snap.weekly?.percent ?? -1, 48.0, accuracy: 0.001)
    }

    func testParsesMax20Fixture() throws {
        let text = try loadFixture("usage_max20")
        let snap = try parser.parse(text, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snap.session.percent, 88.0, accuracy: 0.001)
        XCTAssertEqual(snap.weekly?.percent ?? -1, 82.0, accuracy: 0.001)
        XCTAssertNotNil(snap.session.resetAt)
    }

    func testParseFailureOnJunk() {
        XCTAssertThrowsError(try parser.parse("Hello world, no numbers here."))
    }

    func testResetInMinutesOnly() throws {
        let text = "Session: 10% (resets in 45m)"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = try parser.parse(text, now: now)
        guard let reset = snap.session.resetAt else {
            XCTFail("expected reset date")
            return
        }
        let diff = reset.timeIntervalSince(now)
        XCTAssertEqual(diff, 45 * 60, accuracy: 1)
    }

    // MARK: - helpers

    private func loadFixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "txt")
        guard let url else {
            XCTFail("fixture \(name).txt not found")
            throw NSError(domain: "fixtures", code: 1)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
