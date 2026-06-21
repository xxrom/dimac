import DimacCore
import Foundation

final class UnavailableInternalBrightnessController: InternalBrightnessManaging {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        throw error
    }

    func setBrightness(percent: Int) throws {
        throw error
    }

    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        throw error
    }
}
