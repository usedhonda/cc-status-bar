import XCTest
@testable import CCStatusBarLib

final class CodexRefreshCoordinatorTests: XCTestCase {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func get() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            body(&value)
            lock.unlock()
        }
    }

    func testStaleCacheAndNewPaneReturnCorrectedInitialSnapshot() async {
        let value = LockedBox(["pane-1.14"])
        let coordinator = CodexRefreshCoordinator<[String]>(freshTTL: 0.01) {
            value.get()
        }

        _ = await coordinator.snapshot(deadline: 1)
        value.set(["pane-1.15"])
        coordinator.invalidate()

        let snapshot = await coordinator.snapshot(deadline: 1)
        XCTAssertEqual(snapshot.source, "refresh")
        XCTAssertEqual(snapshot.value, ["pane-1.15"])
    }

    func testConcurrentSubscribersUseOneScan() async {
        let scans = LockedBox(0)
        let coordinator = CodexRefreshCoordinator<String> {
            scans.update { $0 += 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "live"
        }

        let tasks = (0..<8).map { _ in
            Task { await coordinator.snapshot(deadline: 1) }
        }
        let snapshots = await tasks.asyncMap { await $0.value }

        XCTAssertEqual(scans.get(), 1)
        XCTAssertEqual(snapshots.compactMap(\.value), Array(repeating: "live", count: 8))
    }

    func testDeadlineOverrunTriggersExactlyOneCorrectiveCompletion() async {
        let callbacks = LockedBox(0)
        let coordinator = CodexRefreshCoordinator<String>(
            scan: {
                try? await Task.sleep(nanoseconds: 120_000_000)
                return "corrected"
            },
            onApplied: { _ in callbacks.update { $0 += 1 } }
        )

        let timedOut = await coordinator.snapshot(deadline: 0.01)
        XCTAssertEqual(timedOut.source, "deadline")
        XCTAssertNil(timedOut.value)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(callbacks.get(), 1)
        let corrected = await coordinator.snapshot(deadline: 0.1)
        XCTAssertEqual(corrected.value, "corrected")
    }

    func testOldRefreshCannotOverwriteNewGeneration() async {
        let scans = LockedBox(0)
        let coordinator = CodexRefreshCoordinator<String> {
            let scan = scans.get()
            scans.update { $0 += 1 }
            if scan == 0 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                return "old"
            }
            return "new"
        }

        let old = Task { await coordinator.snapshot(deadline: 1) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        coordinator.beginNewGenerationForTesting()
        let current = await coordinator.snapshot(deadline: 1)
        _ = await old.value

        XCTAssertEqual(current.value, "new")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let final = await coordinator.snapshot(deadline: 0.1)
        XCTAssertEqual(final.value, "new")
    }

    func testPaneIndexReuseCannotMapOldSession() {
        let old = makePane(paneID: "%50", panePID: 100, agentPID: 200)
        let reused = makePane(paneID: "%51", panePID: 101, agentPID: 201)
        XCTAssertFalse(CodexObserver.stablePaneIdentityMatches(old, reused))
    }

    func testProcessRemovalConvergesToEmptySnapshot() async {
        let value = LockedBox(["live"])
        let coordinator = CodexRefreshCoordinator<[String]>(freshTTL: 0.01) { value.get() }
        _ = await coordinator.snapshot(deadline: 1)
        value.set([])
        coordinator.invalidate()

        let snapshot = await coordinator.snapshot(deadline: 1)
        XCTAssertEqual(snapshot.source, "refresh")
        XCTAssertEqual(snapshot.value, [])
    }

    func testRefreshFailureRecoversOnNextSuccess() async {
        enum Failure: Error { case unavailable }
        let attempts = LockedBox(0)
        let coordinator = CodexRefreshCoordinator<String> {
            let attempt = attempts.get()
            attempts.update { $0 += 1 }
            if attempt == 0 { throw Failure.unavailable }
            return "recovered"
        }

        let failed = await coordinator.snapshot(deadline: 1)
        XCTAssertEqual(failed.source, "refresh-failure")
        XCTAssertNil(failed.value)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let recovered = await coordinator.snapshot(deadline: 1)
        XCTAssertEqual(recovered.value, "recovered")
        XCTAssertEqual(attempts.get(), 2)
    }

    private func makePane(paneID: String, panePID: pid_t, agentPID: pid_t) -> CodexStableTmuxInfo {
        CodexStableTmuxInfo(
            paneID: paneID,
            panePID: panePID,
            panePIDStart: "pane-start-\(panePID)",
            agentPID: agentPID,
            agentPIDStart: "agent-start-\(agentPID)",
            session: "tproj-workspace",
            window: "1",
            pane: "15",
            socketPath: nil
        )
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(await transform(element))
        }
        return result
    }
}
