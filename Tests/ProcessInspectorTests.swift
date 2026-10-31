import Foundation
import XCTest
@testable import CCStatusBarLib

/// These replaced `pgrep`, `ps` and `lsof`, so they are checked against real processes.
final class ProcessInspectorTests: XCTestCase {
    func testFindsAndDescribesARunningProcess() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier

        XCTAssertTrue(ProcessInspector.pids(named: ["sleep"]).contains(pid))
        XCTAssertFalse(ProcessInspector.pids(named: ["slee"]).contains(pid))
        XCTAssertEqual(ProcessInspector.commandLine(of: pid), "/bin/sleep 30")
        XCTAssertEqual(ProcessInspector.commandLine(of: 99_999), "")
    }

    func testOpenFilesSeesWorkingDirectoryAndOpenFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-inspector-\(UUID().uuidString).jsonl")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let files = ProcessInspector.openFiles(of: getpid())
        XCTAssertEqual(
            files.cwd,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        )
        XCTAssertTrue(files.paths.contains { $0.hasSuffix(url.lastPathComponent) })

        let gone = ProcessInspector.openFiles(of: 99_999)
        XCTAssertNil(gone.cwd)
        XCTAssertEqual(gone.paths, [])
    }

    func testCommandLineStopsAtArgcAndIgnoresTheEnvironment() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/bin/tool".utf8) + [0, 0, 0, 0]
        bytes += Array("tool".utf8) + [0] + Array("with space".utf8) + [0]
        bytes += Array("SECRET=1".utf8) + [0]
        XCTAssertEqual(ProcessInspector.commandLine(fromProcArgs: bytes[...]), "tool with space")
        XCTAssertEqual(ProcessInspector.commandLine(fromProcArgs: [][...]), "")
    }
}
