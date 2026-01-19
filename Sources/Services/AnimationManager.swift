import Foundation
import AppKit

/// Manages menu bar spinner animation for running sessions
@MainActor
final class AnimationManager {
    static let shared = AnimationManager()

    private var timer: Timer?
    private var frameIndex = 0
    private let spinnerFrames = ["◴", "◷", "◶", "◵"]

    /// Callback invoked on each frame update
    var onFrameUpdate: (() -> Void)?

    /// Current spinner character for display
    var currentSpinnerFrame: String {
        spinnerFrames[frameIndex % spinnerFrames.count]
    }

    /// Whether animation is currently running
    var isAnimating: Bool { timer != nil }

    /// Start the spinner animation (100ms interval)
    func startAnimation() {
        guard timer == nil else { return }

        // Check Reduce Motion accessibility setting
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            DebugLog.log("[AnimationManager] Reduce Motion enabled, skipping animation")
            return
        }

        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.frameIndex += 1
                self?.onFrameUpdate?()
            }
        }
        // Use .common mode to keep animation running while menu is open
        RunLoop.main.add(timer!, forMode: .common)
        DebugLog.log("[AnimationManager] Animation started")
    }

    /// Stop the spinner animation
    func stopAnimation() {
        timer?.invalidate()
        timer = nil
        frameIndex = 0
        DebugLog.log("[AnimationManager] Animation stopped")
    }
}
