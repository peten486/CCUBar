import XCTest
@testable import CCUBar

final class NotifierTests: XCTestCase {
    func testCrossingUpwardTriggersThreshold() {
        let crossed = ThresholdDetector.newlyCrossed(previous: 70, current: 76, alreadyNotified: [])
        XCTAssertEqual(crossed, [75])
    }

    func testNoDuplicateNotification() {
        let crossed = ThresholdDetector.newlyCrossed(previous: 80, current: 82, alreadyNotified: [75])
        XCTAssertEqual(crossed, [])
    }

    func testDownwardCrossingDoesNotTrigger() {
        let crossed = ThresholdDetector.newlyCrossed(previous: 80, current: 40, alreadyNotified: [75])
        XCTAssertEqual(crossed, [])
    }

    func testMultipleThresholdsAtOnce() {
        let crossed = ThresholdDetector.newlyCrossed(previous: 50, current: 92, alreadyNotified: [])
        XCTAssertEqual(crossed, [75, 90])
    }

    func testNoPreviousTreatedAsBelow() {
        let crossed = ThresholdDetector.newlyCrossed(previous: nil, current: 80, alreadyNotified: [])
        XCTAssertEqual(crossed, [75])
    }
}
