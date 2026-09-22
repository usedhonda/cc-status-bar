import XCTest
@testable import CCStatusBarLib

/// `tmux capture-pane -p` ends with a newline and pads a short pane with blank
/// lines, so the Codex composer can sit outside a naive tail window.
final class CodexPaneTailTests: XCTestCase {

    /// Byte-for-byte what a live idle Codex pane produced, trailing newline included.
    private let capturedIdlePane =
        "• You have 2 usage limit\n" +
        "resets available. Run /usage\n" +
        "to use one.\n" +
        "\n" +
        "\n" +
        "› Ask Codex to do anything\n" +
        "\n" +
        "  gpt-5.5 high · ~/projects/…\n"

    @MainActor
    func testIdleIsDetectedDespiteTheTrailingNewlineAndPadding() {
        let detected = CodexStatusReceiver.detectWaitingInputFromPane(capturedIdlePane)
        XCTAssertEqual(detected?.reason, .idle)
        XCTAssertEqual(detected?.source, "pane_idle_prompt")
    }

    @MainActor
    func testQuestionPromptIsDetectedDespiteTrailingBlankLines() {
        let capture = """
        Question 1/1 (1 unanswered)
        1. Start now
        2. Later

        enter to submit answer


        """
        let detected = CodexStatusReceiver.detectWaitingInputFromPane(capture)
        XCTAssertEqual(detected?.source, "pane_question_prompt")
    }
}
