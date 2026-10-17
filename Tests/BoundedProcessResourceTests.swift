import XCTest
@testable import CCStatusBarLib

final class BoundedProcessResourceTests: XCTestCase {
    func testRepeatedHelpersDoNotExhaustPipeDescriptors() throws {
        func descriptorCount() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        }
        let before = try descriptorCount()
        for _ in 0..<100 {
            let result = try XCTUnwrap(BoundedProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 2
            ))
            XCTAssertEqual(result.status, 0)
        }
        XCTAssertLessThanOrEqual(try descriptorCount(), before + 8,
            "Helper pipes must be released before the next scan, not at a background task's eventual pool drain")
    }
}
