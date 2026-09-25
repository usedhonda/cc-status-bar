#!/usr/bin/env swift
///
/// Reproduction script for CCStatusBar SIGSEGV crash
///
/// Crash signature:
///   EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0000000000000000
///   PinnedSessionRowView.body → EnvironmentResolver.resolve()
///     → ITerm2Helper.getTabIndexByTTY() → NSAppleScript.executeAndReturnError()
///       → nested RunLoop → CFRunLoop observer callback = NULL → 💥
///
/// Usage: swift scripts/repro-crash.swift
/// Requires: iTerm2 running
///

import Foundation
import AppKit

// MARK: - Check iTerm2 is running

let iTermRunning = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.googlecode.iterm2"
).first != nil

guard iTermRunning else {
    print("❌ iTerm2 is not running. This crash requires iTerm2.")
    print("   Please open iTerm2 and re-run this script.")
    exit(1)
}

print("✅ iTerm2 is running")
print()

// MARK: - Test 1: Prove NSAppleScript blocks main thread

print("═══════════════════════════════════════════════════════════")
print("TEST 1: NSAppleScript blocks main thread")
print("  SwiftUI body must complete in < 16ms (60fps).")
print("  If AppleScript exceeds this, it proves the rendering")
print("  pipeline is blocked, creating conditions for SIGSEGV.")
print("═══════════════════════════════════════════════════════════")

let iterations = 5
var durations: [TimeInterval] = []

for i in 0..<iterations {
    let script = NSAppleScript(source: """
        tell application "iTerm"
            try
                set w to current window
                if w is missing value then return "-1"
                set tabList to tabs of w
                repeat with idx from 1 to count of tabList
                    set t to item idx of tabList
                    repeat with s in sessions of t
                        if tty of s is "/dev/ttys999" then
                            return (idx - 1) as string
                        end if
                    end repeat
                end repeat
                return "-1"
            on error
                return "-1"
            end try
        end tell
        """)!

    let start = CFAbsoluteTimeGetCurrent()
    var error: NSDictionary?
    _ = script.executeAndReturnError(&error)
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    durations.append(elapsed)
    let ms = elapsed * 1000
    let status = ms > 16 ? "⚠️  BLOCKS RENDER" : "✅ OK"
    print("  Run \(i + 1): \(String(format: "%6.1f", ms))ms  \(status)")
}

let avgMs = durations.reduce(0, +) / Double(durations.count) * 1000
let maxMs = durations.max()! * 1000
print()
print("  Average: \(String(format: "%.1f", avgMs))ms")
print("  Max:     \(String(format: "%.1f", maxMs))ms")
print("  Verdict: \(avgMs > 16 ? "⚠️  CONFIRMED — AppleScript blocks main thread beyond frame budget" : "✅ Fast enough")")
print()

// MARK: - Test 2: RunLoop observers fire during AppleScript

print("═══════════════════════════════════════════════════════════")
print("TEST 2: Nested RunLoop allows observers to fire")
print("  NSAppleScript.executeAndReturnError() runs a nested")
print("  RunLoop. SwiftUI registers RunLoop observers for its")
print("  display cycle. If these fire during AppleScript, the")
print("  re-entrant render can hit a null function pointer.")
print("═══════════════════════════════════════════════════════════")

var observerFiredCount = 0
var observerActivities: Set<String> = []

let observer = CFRunLoopObserverCreateWithHandler(
    kCFAllocatorDefault,
    CFRunLoopActivity.allActivities.rawValue,
    true,  // repeats
    0,     // order
    { _, act in
        observerFiredCount += 1
        if act.contains(.entry) { observerActivities.insert("entry") }
        if act.contains(.beforeTimers) { observerActivities.insert("beforeTimers") }
        if act.contains(.beforeSources) { observerActivities.insert("beforeSources") }
        if act.contains(.beforeWaiting) { observerActivities.insert("beforeWaiting") }
        if act.contains(.afterWaiting) { observerActivities.insert("afterWaiting") }
        if act.contains(.exit) { observerActivities.insert("exit") }
    }
)!

CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)

let script = NSAppleScript(source: """
    tell application "iTerm"
        try
            set w to current window
            if w is missing value then return "-1"
            set tabList to tabs of w
            repeat with idx from 1 to count of tabList
                set t to item idx of tabList
                repeat with s in sessions of t
                    if tty of s is "/dev/ttys999" then
                        return (idx - 1) as string
                    end if
                end repeat
            end repeat
            return "-1"
        on error
            return "-1"
        end try
    end tell
    """)!

var asError: NSDictionary?
_ = script.executeAndReturnError(&asError)

CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode)

print("  Observer fired \(observerFiredCount) times during AppleScript execution")
print("  Activities observed: \(observerActivities.sorted().joined(separator: ", "))")
print("  Verdict: \(observerFiredCount > 0 ? "⚠️  CONFIRMED — RunLoop observers fire during AppleScript" : "❌ Observers did not fire")")
print()

if observerFiredCount > 0 {
    print("  This is the crash mechanism:")
    print("  1. SwiftUI body calls ITerm2Helper.getTabIndexByTTY()")
    print("  2. NSAppleScript.executeAndReturnError() spins nested RunLoop")
    print("  3. During nested RunLoop, SwiftUI's display-cycle observer fires")
    print("  4. SwiftUI tries to re-enter body evaluation")
    print("  5. If the view was invalidated, the observer callback is NULL → SIGSEGV")
    print()
}

// MARK: - Test 3: Simulate rapid resolves (production crash pattern)

print("═══════════════════════════════════════════════════════════")
print("TEST 3: Simulated production crash pattern")
print("  In production, PinnedSessionRowView.body computes a")
print("  `env` property that calls EnvironmentResolver.resolve()")
print("  which calls ITerm2Helper.getTabIndexByTTY().")
print("  Multiple sessions × cache expiry = repeated blocking.")
print("═══════════════════════════════════════════════════════════")

let sessionCount = 4
let cycles = 3
let fullStart = CFAbsoluteTimeGetCurrent()

for _ in 0..<cycles {
    for s in 0..<sessionCount {
        let tty = "/dev/ttys\(String(format: "%03d", 900 + s))"
        let innerScript = NSAppleScript(source: """
            tell application "iTerm"
                try
                    set w to current window
                    if w is missing value then return "-1"
                    set tabList to tabs of w
                    repeat with idx from 1 to count of tabList
                        set t to item idx of tabList
                        repeat with sess in sessions of t
                            if tty of sess is "\(tty)" then
                                return (idx - 1) as string
                            end if
                        end repeat
                    end repeat
                    return "-1"
                on error
                    return "-1"
                end try
            end tell
            """)!

        var innerError: NSDictionary?
        _ = innerScript.executeAndReturnError(&innerError)
    }
}

let fullElapsed = (CFAbsoluteTimeGetCurrent() - fullStart) * 1000
let totalCalls = cycles * sessionCount
print("  \(totalCalls) AppleScript calls (simulating \(sessionCount) sessions × \(cycles) render cycles)")
print("  Total main thread blocked: \(String(format: "%.0f", fullElapsed))ms")
print("  Avg per call: \(String(format: "%.1f", fullElapsed / Double(totalCalls)))ms")
print("  Verdict: \(fullElapsed > 100 ? "⚠️  CONFIRMED — Main thread blocked \(String(format: "%.0f", fullElapsed))ms" : "✅ Within budget")")
print()

// MARK: - Summary

print("═══════════════════════════════════════════════════════════")
print("SUMMARY")
print("═══════════════════════════════════════════════════════════")
print()
print("Root cause: PinnedSessionRowView.body synchronously calls")
print("NSAppleScript.executeAndReturnError() via:")
print()
print("  PinnedSessionRowView.body")
print("    → env (computed property)")
print("      → EnvironmentResolver.resolve(session:)")
print("        → resolveUncached(session:)")
print("          → ITerm2Helper.getTabIndexByTTY()")
print("            → NSAppleScript.executeAndReturnError()  ← blocks + nested RunLoop")
print()
print("The nested RunLoop allows SwiftUI observers to fire re-entrantly.")
print("When the view is invalidated during this nested execution,")
print("the observer callback becomes NULL → SIGSEGV at address 0x0.")
print()

let allConfirmed = avgMs > 16 && observerFiredCount > 0 && fullElapsed > 100
if allConfirmed {
    print("🔴 ALL THREE CONDITIONS CONFIRMED:")
    print("   1. AppleScript blocks main thread > 16ms (avg \(String(format: "%.0f", avgMs))ms)")
    print("   2. RunLoop observers fire during AppleScript (\(observerFiredCount) times)")
    print("   3. Multiple sessions compound the blocking (\(String(format: "%.0f", fullElapsed))ms total)")
    print()
    print("Fix: Move AppleScript execution off the SwiftUI body render path.")
    print("     Use @State + .task{} for async resolution, or pre-resolve in SessionObserver.")
} else {
    print("⚠️  Not all conditions reproduced. Some tests may need iTerm2 with multiple tabs.")
}
print()
