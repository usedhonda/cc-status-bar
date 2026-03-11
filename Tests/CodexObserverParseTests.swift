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

    // MARK: - parseCodexSessionFileExtended

    func testParseExtendedValidSession() {
        let json = """
        {"type":"session_meta","payload":{"id":"sess-ext-1","cwd":"/tmp/project","cli_version":"1.0.7","model_provider":"openai","originator":"codex-cli"}}
        {"type":"message","content":"working..."}
        {"type":"token_count","payload":{"input_tokens":400000,"output_tokens":121000,"total_tokens":521000}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFileExtended(url, lookingForCwd: "/tmp/project")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, "sess-ext-1")
        XCTAssertEqual(result?.cliVersion, "1.0.7")
        XCTAssertEqual(result?.modelProvider, "openai")
        XCTAssertEqual(result?.originator, "codex-cli")
        XCTAssertEqual(result?.tokenUsage?.inputTokens, 400000)
        XCTAssertEqual(result?.tokenUsage?.outputTokens, 121000)
        XCTAssertEqual(result?.tokenUsage?.totalTokens, 521000)
        XCTAssertEqual(result?.tokenUsage?.formattedTotal, "521K tokens")
    }

    func testParseExtendedNoTokenCount() {
        let json = """
        {"type":"session_meta","payload":{"id":"sess-ext-2","cwd":"/tmp/project","cli_version":"1.0.5"}}
        {"type":"message","content":"hello"}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFileExtended(url, lookingForCwd: "/tmp/project")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, "sess-ext-2")
        XCTAssertEqual(result?.cliVersion, "1.0.5")
        XCTAssertNil(result?.tokenUsage)
    }

    func testParseExtendedMismatchedCwd() {
        let json = """
        {"type":"session_meta","payload":{"id":"sess-ext-3","cwd":"/tmp/other"}}
        {"type":"token_count","payload":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFileExtended(url, lookingForCwd: "/tmp/project")
        XCTAssertNil(result)
    }

    func testParseExtendedPicksLatestTokenCount() {
        let json = """
        {"type":"session_meta","payload":{"id":"sess-ext-4","cwd":"/tmp/project"}}
        {"type":"token_count","payload":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}
        {"type":"message","content":"more work"}
        {"type":"token_count","payload":{"input_tokens":500,"output_tokens":200,"total_tokens":700}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFileExtended(url, lookingForCwd: "/tmp/project")
        XCTAssertEqual(result?.tokenUsage?.totalTokens, 700)
    }

    func testParseExtendedNestedEventMsgFormat() {
        // Real Codex JSONL uses event_msg wrapper with nested total_token_usage
        let json = """
        {"type":"session_meta","payload":{"id":"sess-nested","cwd":"/tmp/project","cli_version":"0.114.0","model_provider":"openai","originator":"codex_exec"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":511083,"cached_input_tokens":415616,"output_tokens":10150,"reasoning_output_tokens":6506,"total_tokens":521233},"last_token_usage":{"input_tokens":65421},"model_context_window":258400},"rate_limits":null}}
        """
        let url = writeSessionFile(json)
        let result = CodexObserver.parseCodexSessionFileExtended(url, lookingForCwd: "/tmp/project")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, "sess-nested")
        XCTAssertEqual(result?.cliVersion, "0.114.0")
        XCTAssertEqual(result?.modelProvider, "openai")
        XCTAssertEqual(result?.originator, "codex_exec")
        XCTAssertEqual(result?.tokenUsage?.inputTokens, 511083)
        XCTAssertEqual(result?.tokenUsage?.outputTokens, 10150)
        XCTAssertEqual(result?.tokenUsage?.totalTokens, 521233)
        XCTAssertEqual(result?.tokenUsage?.formattedTotal, "521.2K tokens")
    }

    // MARK: - CodexTokenUsage formatting

    func testTokenUsageFormatSmall() {
        XCTAssertEqual(CodexTokenUsage.format(500), "500 tokens")
    }

    func testTokenUsageFormatThousands() {
        XCTAssertEqual(CodexTokenUsage.format(521000), "521K tokens")
    }

    func testTokenUsageFormatMillions() {
        XCTAssertEqual(CodexTokenUsage.format(1500000), "1.5M tokens")
    }

    func testTokenUsageFormatExactThousand() {
        XCTAssertEqual(CodexTokenUsage.format(1000), "1K tokens")
    }

    func testTokenUsageFormatFractionalThousand() {
        XCTAssertEqual(CodexTokenUsage.format(1500), "1.5K tokens")
    }
}
