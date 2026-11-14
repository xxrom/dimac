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
        XCTAssertEqual(displays[2].uuid, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertNil(displays[0].uuid)
    }

    func testCapturesUUIDAcrossFormatsWithoutRemovingOrdinaryParentheses() {
        let displays = M1DDCDisplayListParser().parse("""
        1: Dell (USB-C) (37d8832a-2d66-02ca-b9f7-8f30a301b230)
        Display 2 - Dell (USB-C) (37D8832A-2D66-02CA-B9F7-8F30A301B231)
        [3] Dell (USB-C)
        """)

        XCTAssertEqual(displays.map(\.name), Array(repeating: "Dell (USB-C)", count: 3))
        XCTAssertEqual(displays[0].uuid, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertEqual(displays[1].uuid, "37D8832A-2D66-02CA-B9F7-8F30A301B231")
        XCTAssertNil(displays[2].uuid)
    }

    func testIgnoresUnnumberedLines() {
        let parser = M1DDCDisplayListParser()
        XCTAssertTrue(parser.parse("Could not find a suitable external display.").isEmpty)
    }

    func testEmptyOutputHasNoDisplays() {
        let parser = M1DDCDisplayListParser()
        XCTAssertTrue(parser.parse("").isEmpty)
        XCTAssertTrue(parser.parse("\n  \n\t\n").isEmpty)
    }

    func testNullUUIDIsTreatedAsAbsent() {
        let displays = M1DDCDisplayListParser().parse("""
        [1] Dell U2720Q ((null))
        [2] LG UltraFine (null)
        [3] (null) (NULL)
        2: (null)
        """)

        XCTAssertEqual(displays.map(\.name), ["Dell U2720Q", "LG UltraFine", "Display 3", "Display 2"])
        XCTAssertTrue(displays.allSatisfy { $0.uuid == nil })
    }

    func testBareNumberLinesAreNotDisplays() {
        let displays = M1DDCDisplayListParser().parse("""
        60 Hz
        2560 x 1440
        100
        1.5 nits
        4 -5
        1) Dell
        2. LG
        3 - BenQ
        """)

        XCTAssertEqual(displays.map(\.selector), ["1", "2", "3"])
        XCTAssertEqual(displays.map(\.name), ["Dell", "LG", "BenQ"])
    }
}
