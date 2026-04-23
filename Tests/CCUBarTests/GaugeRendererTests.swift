import XCTest
@testable import CCUBar

final class GaugeRendererTests: XCTestCase {
    func testRenderBoundaries() {
        XCTAssertEqual(GaugeRenderer.render(percent: 0), "[░░░░░░░░░░] 0%")
        XCTAssertEqual(GaugeRenderer.render(percent: 100), "[██████████] 100%")
        XCTAssertTrue(GaugeRenderer.render(percent: 50).contains("50%"))
    }

    func testClampBelowZero() {
        XCTAssertEqual(GaugeRenderer.render(percent: -10), "[░░░░░░░░░░] 0%")
    }

    func testClampAboveHundred() {
        XCTAssertEqual(GaugeRenderer.render(percent: 150), "[██████████] 100%")
    }

    func testTiers() {
        XCTAssertEqual(GaugeRenderer.tier(for: 0), .normal)
        XCTAssertEqual(GaugeRenderer.tier(for: 59.9), .normal)
        XCTAssertEqual(GaugeRenderer.tier(for: 60), .warning)
        XCTAssertEqual(GaugeRenderer.tier(for: 84.99), .warning)
        XCTAssertEqual(GaugeRenderer.tier(for: 85), .critical)
        XCTAssertEqual(GaugeRenderer.tier(for: 100), .critical)
    }

    func testLoadingRender() {
        XCTAssertEqual(GaugeRenderer.renderLoading(), "[··········] ---%")
    }
}
