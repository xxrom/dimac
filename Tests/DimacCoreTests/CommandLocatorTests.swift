import DimacCore
import XCTest

final class CommandLocatorTests: XCTestCase {
    func testResolvePrefersFirstExecutableCandidate() {
        let resolved = CommandLocator.resolve(
            candidates: ["/missing/one", "/found/two", "/found/three"],
            isExecutable: { $0.hasPrefix("/found") }
        )

        XCTAssertEqual(resolved, "/found/two")
    }

    func testResolveFallsBackToFirstCandidateWhenNothingExists() {
        let resolved = CommandLocator.resolve(
            candidates: ["/first", "/second"],
            isExecutable: { _ in false }
        )

        XCTAssertEqual(resolved, "/first")
    }
}
