import XCTest
@testable import CCStatusBarLib

final class SoundPlayerTests: XCTestCase {
    func testResolveSoundPathUsesDefaultForBeepSetting() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "beep",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/System/Library/Sounds/Ping.aiff" }
        )

        XCTAssertEqual(resolved, "/System/Library/Sounds/Ping.aiff")
    }

    func testResolveSoundPathReturnsNilWhenNoDefaultExists() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "beep",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { _ in false }
        )

        XCTAssertNil(resolved)
    }

    func testResolveSoundPathKeepsCustomWhenPresent() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "/tmp/custom.aiff",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/tmp/custom.aiff" }
        )

        XCTAssertEqual(resolved, "/tmp/custom.aiff")
    }

    func testResolveSoundPathFallsBackToDefaultWhenCustomMissing() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "/tmp/missing.aiff",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/System/Library/Sounds/Ping.aiff" }
        )

        XCTAssertEqual(resolved, "/System/Library/Sounds/Ping.aiff")
    }

    func testResolveSoundPathTreatsEmptyAsDefault() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/System/Library/Sounds/Ping.aiff" }
        )

        XCTAssertEqual(resolved, "/System/Library/Sounds/Ping.aiff")
    }
}
