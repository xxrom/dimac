import DimacCore
import XCTest

final class DimmerSettingsTests: XCTestCase {
    func testDimPercentClampsToSupportedRange() {
        XCTAssertEqual(DimmerSettings.clampedPercent(-10), 1)
        XCTAssertEqual(DimmerSettings.clampedPercent(0), 1)
        XCTAssertEqual(DimmerSettings.clampedPercent(10), 10)
        XCTAssertEqual(DimmerSettings.clampedPercent(140), 100)
    }

    func testIdleTimeoutHasMinimum() {
        let settings = DimmerSettings(idleTimeoutSeconds: 0)
        XCTAssertEqual(settings.idleTimeoutSeconds, 1)
    }

    func testExternalBrightnessPreferencesClampToSupportedRange() {
        let settings = DimmerSettings(
            externalBrightnessByDisplay: [
                "low": 0,
                "ok": 55,
                "high": 140
            ]
        )

        XCTAssertEqual(settings.externalBrightnessByDisplay["low"], 1)
        XCTAssertEqual(settings.externalBrightnessByDisplay["ok"], 55)
        XCTAssertEqual(settings.externalBrightnessByDisplay["high"], 100)
    }
}
