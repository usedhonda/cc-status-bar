import AppKit
import Carbon
import XCTest
@testable import CCStatusBarLib

final class HotkeyManagerTests: XCTestCase {
    func testCarbonModifiersFromEventFlags() {
        XCTAssertEqual(
            HotkeyManager.carbonModifiers(from: [.command, .option]),
            UInt32(cmdKey | optionKey)
        )
        XCTAssertEqual(
            HotkeyManager.carbonModifiers(from: [.control, .shift, .capsLock, .function]),
            UInt32(controlKey | shiftKey)
        )
        XCTAssertEqual(HotkeyManager.carbonModifiers(from: []), 0)
    }

    func testHotkeyNeedsCommandControlOrOption() {
        XCTAssertTrue(HotkeyManager.isAcceptableHotkey(modifiers: UInt32(cmdKey)))
        XCTAssertTrue(HotkeyManager.isAcceptableHotkey(modifiers: UInt32(optionKey | shiftKey)))
        XCTAssertFalse(HotkeyManager.isAcceptableHotkey(modifiers: UInt32(shiftKey)))
        XCTAssertFalse(HotkeyManager.isAcceptableHotkey(modifiers: 0))
    }

    /// Key code 0 is the A key; it used to be read back as "unset".
    func testStoredKeyCodeZeroIsNotTheDefault() {
        let fallback = UInt32(kVK_ANSI_C)
        XCTAssertEqual(HotkeyManager.storedKeyCode(0, default: fallback), UInt32(kVK_ANSI_A))
        XCTAssertEqual(HotkeyManager.storedKeyCode(nil, default: fallback), fallback)
        XCTAssertEqual(HotkeyManager.storedKeyCode(Int(kVK_ANSI_K), default: fallback), UInt32(kVK_ANSI_K))
    }

    func testDescribeOrdersModifiersAndNamesSpecialKeys() {
        XCTAssertEqual(
            HotkeyManager.describe(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
            "⌘⇧Space"
        )
        XCTAssertEqual(
            HotkeyManager.describe(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey | controlKey)),
            "⌥⌃F5"
        )
    }
}
