import SwiftUI

struct CCStatusBarApp: App {
    // Minimal test: SessionObserver temporarily disabled
    // @StateObject private var observer = SessionObserver()

    var body: some Scene {
        MenuBarExtra("CC", systemImage: "circle.fill") {
            Text("Hello - Test")
        }
        // .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var observer: SessionObserver

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: statusIcon)
            if observer.waitingCount > 0 {
                Text("\(observer.waitingCount)")
                    .font(.system(size: 10, weight: .bold))
            }
        }
    }

    private var statusIcon: String {
        if observer.waitingCount > 0 {
            return "exclamationmark.circle.fill"
        } else if observer.runningCount > 0 {
            return "circle.fill"
        } else {
            return "circle"
        }
    }
}
