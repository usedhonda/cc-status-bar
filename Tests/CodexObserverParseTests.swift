import XCTest
@testable import CCStatusBarLib

final class CodexObserverParseTests: XCTestCase {

    // MARK: - Helper

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexObserverParseTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeSessionFile(_ content: String) -> URL {
        let url = tempDir.appendingPathComponent("rollout-test.jsonl")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - parseCodexSessionFile

    func testParseValidSessionMeta() {
        let json = """
        {"type":"session_meta","payload":{"id":"sess-123","cwd":"/tmp/project"}}
        {"type":"message","content":"hello"}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertEqual(result, "sess-123")
    }

    func testParseMismatchedCwd() {
        let json = """
        {"type":"session_meta","payload":{"id":"sess-123","cwd":"/tmp/other"}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseInvalidJSON() {
        let url = writeSessionFile("this is not json at all")
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseMissingFields() {
        // Missing "type" field
        let json = """
        {"payload":{"id":"sess-123","cwd":"/tmp/project"}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseMissingPayload() {
        let json = """
        {"type":"session_meta"}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseWrongType() {
        let json = """
        {"type":"message","payload":{"id":"sess-123","cwd":"/tmp/project"}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseEmptyFile() {
        let url = writeSessionFile("")
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseMissingSessionId() {
        let json = """
        {"type":"session_meta","payload":{"cwd":"/tmp/project"}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFile(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }
}
