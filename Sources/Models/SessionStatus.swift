import SwiftUI

enum SessionStatus: String, Codable {
    case running = "running"
    case waitingInput = "waiting_input"
    case stopped = "stopped"

    var symbol: String {
        switch self {
        case .running: return "●"
        case .waitingInput: return "◐"
        case .stopped: return "✓"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .waitingInput: return .yellow
        case .stopped: return .secondary
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waitingInput: return "Waiting"
        case .stopped: return "Done"
        }
    }
}
