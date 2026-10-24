#!/usr/bin/env python3
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
os.chdir(root)
os.environ.setdefault('CLANG_MODULE_CACHE_PATH', '/tmp/dimac-clang-cache')
os.environ.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', '/tmp/dimac-swift-cache')
sdk = os.environ.get('SDKROOT')
subprocess.run(['swift', 'build', '--disable-sandbox', '--build-system', 'native'] + (['--sdk', sdk] if sdk else []), check=True)
build = root / '.build/debug'
objects = list((build / 'DimacCore.build').glob('*.swift.o')) + [p for p in (build / 'Dimac.build').glob('*.swift.o') if p.name != 'DimacApp.swift.o']
shim = r'''
@MainActor class XCTestCase {
    var teardownBlocks: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { teardownBlocks.append(block) }
    func finish() { for block in teardownBlocks.reversed() { block() } }
}
func XCTAssertTrue(_ v: Bool) { precondition(v) }
func XCTAssertFalse(_ v: Bool) { precondition(!v) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Values differ: \(a) vs \(b)") }
func XCTAssertEqual<T: FloatingPoint>(_ a: T, _ b: T, accuracy: T) { precondition(abs(a-b) <= accuracy) }
func XCTAssertNil<T>(_ v: T?) { precondition(v == nil) }
func XCTAssertNotNil<T>(_ v: T?) { precondition(v != nil) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T) { precondition(a <= b) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T) { precondition(a > b) }
func XCTAssertThrowsError<T>(_ f: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) { do { _ = try f(); preconditionFailure("Expected error") } catch { handler(error) } }
func XCTUnwrap<T>(_ v: T?) throws -> T { guard let v else { fatalError("Expected value") }; return v }
'''
count = 0
with tempfile.TemporaryDirectory(prefix='dimac-tests-') as tmp:
    for path in sorted((root / 'Tests').glob('*/*.swift')):
        if len(sys.argv) > 1 and sys.argv[1] not in path.name:
            continue
        source = path.read_text()
        if re.search(r'override func|func test[^\n]*async', source):
            raise RuntimeError(f'Unsupported lifecycle/async test in {path}')
        cls = re.search(r'final class (\w+): XCTestCase', source).group(1)
        methods = re.findall(r'func (test\w+)\(\)( throws)?', source)
        calls = '\n'.join(f'print("RUN {cls}.{name}"); do {{ let test = {cls}(); defer {{ test.finish() }}; {"try " if throwing else ""}test.{name}() }}' for name, throwing in methods)
        transformed = source.replace('import XCTest', 'import Foundation')
        swift = Path(tmp) / 'Tests.swift'
        swift.write_text(transformed + shim + '\n@main struct Run { @MainActor static func main() throws {\n' + calls + '\n} }')
        exe = Path(tmp) / 'tests'
        subprocess.run(['swiftc'] + (['-sdk', sdk] if sdk else []) + ['-parse-as-library', '-I', str(build / 'Modules'), str(swift), *map(str, objects), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
        count += len(methods)
print(f'PASS: {count} scenarios (CLT assertion runner)')
