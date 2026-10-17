import XCTest
@testable import CCStatusBarLib

final class CodexAttachmentTests: XCTestCase {
    private func pane(id: String = "%7", agentStart: String? = "agent-start", paneStart: String? = "pane-start") -> CodexStableTmuxInfo {
        CodexStableTmuxInfo(paneID: id, panePID: 10, panePIDStart: paneStart,
            agentPID: 20, agentPIDStart: agentStart, session: "session", window: "1", pane: "0", socketPath: nil)
    }

    func testUniqueVerifiedAncestorPreservesAttachmentCoordinates() {
        let expected = pane()
        XCTAssertEqual(CodexObserver.selectAttachmentPane(candidates: [expected], agentPID: 20,
            agentStartBefore: "agent-start", agentStartAfter: "agent-start", paneStartAfter: "pane-start"), expected)
    }

    func testNoAncestorAndMultipleDifferentAncestorsFailClosed() {
        for candidates in [[], [pane(), pane(id: "%8")]] {
            XCTAssertNil(CodexObserver.selectAttachmentPane(candidates: candidates, agentPID: 20,
                agentStartBefore: "agent-start", agentStartAfter: "agent-start", paneStartAfter: "pane-start"))
        }
    }

    func testMissingChangedOrReusedProcessIdentityFailsClosed() {
        for (before, after, paneAfter): (String?, String?, String?) in [
            (nil, "agent-start", "pane-start"), ("agent-start", nil, "pane-start"),
            ("agent-start", "reused-agent", "pane-start"), ("agent-start", "agent-start", nil),
            ("agent-start", "agent-start", "reused-pane")
        ] {
            XCTAssertNil(CodexObserver.selectAttachmentPane(candidates: [pane()], agentPID: 20,
                agentStartBefore: before, agentStartAfter: after, paneStartAfter: paneAfter))
        }
        for candidate in [pane(agentStart: nil), pane(paneStart: nil)] {
            XCTAssertNil(CodexObserver.selectAttachmentPane(candidates: [candidate], agentPID: 20,
                agentStartBefore: "agent-start", agentStartAfter: "agent-start", paneStartAfter: "pane-start"))
        }
        XCTAssertNil(CodexObserver.selectAttachmentPane(candidates: [pane()], agentPID: 21,
            agentStartBefore: "agent-start", agentStartAfter: "agent-start", paneStartAfter: "pane-start"))
    }

    func testAttachmentCacheDoesNotReplaceStrictIdentityCache() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/CCStatusBarLib/Services/CodexObserver.swift"))
        let strict = try XCTUnwrap(source.range(of: "static func stableTmuxInfo(for session:"))
        let end = try XCTUnwrap(source.range(of: "static func attachmentTmuxInfo(for session:"))
        XCTAssertTrue(source[strict.lowerBound..<end.lowerBound].contains("paneInfoByPID[session.pid]"))
        XCTAssertFalse(source[strict.lowerBound..<end.lowerBound].contains("attachmentInfoByPID[session.pid]"))
        XCTAssertTrue(source.contains("TmuxHelper.normalizeTTY(row.tty) == TmuxHelper.normalizeTTY(tty)"))
    }
}
