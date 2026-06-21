import DimacCore
import XCTest

final class M1DDCDisplayListParserTests: XCTestCase {
    func testParsesNumberedDisplayLines() {
        let parser = M1DDCDisplayListParser()
        let displays = parser.parse("""
        1: LG UltraFine
        Display 2 - MSI PS341WU
        [3] Dell U2720Q (37D8832A-2D66-02CA-B9F7-8F30A301B230)
        ignored line
        """)

        XCTAssertEqual(displays.count, 3)
        XCTAssertEqual(displays[0].selector, "1")
        XCTAssertEqual(displays[0].name, "LG UltraFine")
        XCTAssertEqual(displays[1].selector, "2")
        XCTAssertEqual(displays[1].name, "MSI PS341WU")
        XCTAssertEqual(displays[2].selector, "3")
        XCTAssertEqual(displays[2].name, "Dell U2720Q")
    }

    func testIgnoresUnnumberedLines() {
        let parser = M1DDCDisplayListParser()
        XCTAssertTrue(parser.parse("Could not find a suitable external display.").isEmpty)
    }
}
