import XCTest
@testable import CCStatusBarLib

/// Codex session identity comes from the transcript a process holds open,
/// and existence comes from the process scan — not from hook events.
final class CodexRolloutDiscoveryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRolloutDiscoveryTests-\(UUID().uuidString)")
            .appendingPathComponent(".codex/sessions/2026/09/17")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @discardableResult
    private func writeRollout(_ name: String, meta: String, modifiedAt: Date) -> String {
        let url = tempDir.appendingPathComponent(name)
        try! "\(meta)\n".write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - rolloutPaths(fromLsofOutput:)

    func testRolloutPathsPicksOpenTranscriptsOnly() {
        let output = """
        codex   70114 usedhonda  cwd    DIR  1,13  1024 123 /Users/u/projects/pocket-chi
        codex   70114 usedhonda   19u   REG  1,13  4140632 456 /Users/u/.codex/queue_1.sqlite-wal
        codex   70114 usedhonda   48u   REG  1,13  66393367 789 /Users/u/.codex/sessions/2026/09/17/rollout-2026-09-17T14-36-14-01a0ae14.jsonl
        codex   70114 usedhonda   74u   REG  1,13  1511330 790 /Users/u/.codex/sessions/2026/09/19/rollout-2026-09-19T23-53-30-01a0ba5f.jsonl
        """

        XCTAssertEqual(CodexObserver.cwd(fromLsofOutput: output), "/Users/u/projects/pocket-chi")
        XCTAssertEqual(CodexObserver.rolloutPaths(fromLsofOutput: output), [
            "/Users/u/.codex/sessions/2026/09/17/rollout-2026-09-17T14-36-14-01a0ae14.jsonl",
            "/Users/u/.codex/sessions/2026/09/19/rollout-2026-09-19T23-53-30-01a0ba5f.jsonl",
        ])
    }

    // MARK: - selectPrimaryRollout

    /// Modelled on a live process that had four transcripts open: its own plus
    /// three spawned subagent threads.
    func testSelectPrimaryRolloutPrefersTheParentThreadOverSubagents() {
        let cwd = "/Users/u/projects/pocket-chi"
        let parent = writeRollout(
            "rollout-parent.jsonl",
            meta: """
            {"type":"session_meta","payload":{"id":"01a0ae14","cwd":"\(cwd)","source":"cli","originator":"codex-tui"}}
            """,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        var subagents: [String] = []
        for (index, id) in ["01a0ba5f", "01a0ba60", "01a0ba8f"].enumerated() {
            subagents.append(writeRollout(
                "rollout-sub-\(id).jsonl",
                meta: """
                {"type":"session_meta","payload":{"id":"\(id)","cwd":"\(cwd)",\
                "parent_thread_id":"01a0ae14","source":{"subagent":{"thread_spawn":{"parent_thread_id":"01a0ae14"}}}}}
                """,
                // Subagents are more recently written than the parent.
                modifiedAt: Date(timeIntervalSince1970: 2_000 + TimeInterval(index))
            ))
        }

        let selected = CodexObserver.selectPrimaryRollout(
            candidates: subagents + [parent],
            processCwd: cwd
        )
        XCTAssertEqual(selected, parent)
    }

    func testSelectPrimaryRolloutIgnoresTranscriptsFromAnotherDirectory() {
        let mine = writeRollout(
            "rollout-mine.jsonl",
            meta: """
            {"type":"session_meta","payload":{"id":"mine","cwd":"/Users/u/a","source":"cli"}}
            """,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let theirs = writeRollout(
            "rollout-theirs.jsonl",
            meta: """
            {"type":"session_meta","payload":{"id":"theirs","cwd":"/Users/u/b","source":"cli"}}
            """,
            modifiedAt: Date(timeIntervalSince1970: 9_000)
        )

        XCTAssertEqual(
            CodexObserver.selectPrimaryRollout(candidates: [theirs, mine], processCwd: "/Users/u/a"),
            mine
        )
        XCTAssertNil(
            CodexObserver.selectPrimaryRollout(candidates: [theirs, mine], processCwd: "/Users/u/c")
        )
    }

    /// The session_meta line embeds the user's AGENTS.md, so it can be far
    /// larger than one read buffer. A truncated read used to yield nil.
    func testSelectPrimaryRolloutReadsASessionMetaLineLargerThanOneChunk() {
        let cwd = "/Users/u/projects/big"
        let instructions = String(repeating: "a", count: 200_000)
        let path = writeRollout(
            "rollout-big.jsonl",
            meta: """
            {"type":"session_meta","payload":{"id":"big","cwd":"\(cwd)","source":"cli",\
            "base_instructions":"\(instructions)"}}
            """,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(CodexObserver.selectPrimaryRollout(candidates: [path], processCwd: cwd), path)
    }

    // MARK: - merge(scanned:hookOverlays:)

    private func session(pid: pid_t, cwd: String, sessionId: String? = nil) -> CodexSession {
        var session = CodexSession(pid: pid, cwd: cwd)
        session.sessionId = sessionId
        return session
    }

    /// The store used to own existence, so a process that never delivered a
    /// SessionStart hook stayed invisible for as long as the app ran.
    func testScannedSessionsSurviveWhenHookMetadataIsMissing() {
        let scanned = [
            "codex:1": session(pid: 1, cwd: "/a", sessionId: "from-rollout"),
            "codex:2": session(pid: 2, cwd: "/b"),
        ]
        let merged = CodexObserver.merge(
            scanned: scanned,
            hookOverlays: ["/a": CodexHookOverlay(sessionId: "from-hook", model: "gpt-5.6")]
        )

        XCTAssertEqual(Set(merged.keys), ["codex:1", "codex:2"])
        // A scanned identity wins; the hook only fills gaps.
        XCTAssertEqual(merged["codex:1"]?.sessionId, "from-rollout")
        XCTAssertEqual(merged["codex:1"]?.modelProvider, "gpt-5.6")
        XCTAssertNil(merged["codex:2"]?.sessionId)
    }

    /// Hook metadata for a dead or never-scanned process must not resurrect it.
    func testHookMetadataNeverAddsASession() {
        let merged = CodexObserver.merge(
            scanned: [:],
            hookOverlays: ["/gone": CodexHookOverlay(sessionId: "stale", model: nil)]
        )
        XCTAssertTrue(merged.isEmpty)
    }
}
