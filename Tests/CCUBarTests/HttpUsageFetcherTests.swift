import XCTest
@testable import CCUBar

final class HttpUsageFetcherTests: XCTestCase {
    func testParsesScraperResponse() throws {
        let json = """
        {
            "cached": true,
            "five_hour": {
                "remaining_minutes": 11,
                "resets_at": "2026-04-23T14:29:59.844950+00:00",
                "utilization": 55.0
            },
            "seven_day": {
                "remaining_minutes": 341,
                "resets_at": "2026-04-23T20:00:00.844966+00:00",
                "utilization": 84.0
            },
            "seven_day_sonnet": {
                "remaining_minutes": 4841,
                "resets_at": "2026-04-26T23:00:00.844973+00:00",
                "utilization": 8.0
            },
            "source": "api",
            "timestamp": "2026-04-23T14:18:27Z"
        }
        """.data(using: .utf8)!

        let snap = try HttpUsageFetcher.parseResponse(
            data: json,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(snap.session.percent, 55.0, accuracy: 0.001)
        XCTAssertEqual(snap.weekly?.percent ?? -1, 84.0, accuracy: 0.001)
        XCTAssertEqual(snap.sonnetWeekly?.percent ?? -1, 8.0, accuracy: 0.001)
        XCTAssertEqual(snap.session.remainingMinutes, 11)
        XCTAssertEqual(snap.sonnetWeekly?.remainingMinutes, 4841)
        XCTAssertNotNil(snap.session.resetAt)
        XCTAssertNotNil(snap.weekly?.resetAt)
        XCTAssertNotNil(snap.sonnetWeekly?.resetAt)
        XCTAssertFalse(snap.rawOutput.isEmpty)
    }

    func testMissingFiveHourThrows() {
        let json = #"{"seven_day": {"utilization": 50}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try HttpUsageFetcher.parseResponse(data: json, now: Date()))
    }

    func testIntegerUtilizationCoerces() throws {
        let json = #"{"five_hour": {"utilization": 42}}"#.data(using: .utf8)!
        let snap = try HttpUsageFetcher.parseResponse(data: json, now: Date())
        XCTAssertEqual(snap.session.percent, 42.0, accuracy: 0.001)
        XCTAssertNil(snap.weekly)
        XCTAssertNil(snap.sonnetWeekly)
    }
}
