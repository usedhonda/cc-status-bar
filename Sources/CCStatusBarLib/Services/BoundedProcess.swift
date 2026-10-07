import Foundation

/// The one way this app runs a helper command (tmux, lsof, ps, claude).
enum BoundedProcess {
    /// Run a command with a hard deadline without parking a thread on it.
    ///
    /// Output is drained while the child runs (a child writing more than the
    /// pipe buffer blocks forever if nobody reads), exit is observed through
    /// `terminationHandler` rather than a blocking `waitUntilExit`, and a child
    /// that outlives the deadline gets SIGTERM, then SIGKILL. The previous
    /// version leaked one blocked thread per timeout until GCD's 64-thread
    /// limit starved the web server.
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        killGrace: TimeInterval = 1
    ) -> (status: Int32, stdout: Data, stderr: Data)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lock = NSLock()
        var out = Data()
        var err = Data()
        let outEOF = DispatchSemaphore(value: 0)
        let errEOF = DispatchSemaphore(value: 0)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; outEOF.signal(); return }
            lock.lock(); out.append(chunk); lock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; errEOF.signal(); return }
            lock.lock(); err.append(chunk); lock.unlock()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        func stopReading() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
        } catch {
            stopReading()
            return nil
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGrace)
            }
            stopReading()
            return nil
        }

        // Let the handlers deliver the rest of the output. Never block on the
        // pipe itself: a grandchild still holding it open would hang us here.
        _ = outEOF.wait(timeout: .now() + killGrace)
        _ = errEOF.wait(timeout: .now() + killGrace)
        stopReading()
        lock.lock()
        let result = (process.terminationStatus, out, err)
        lock.unlock()
        return result
    }
}
