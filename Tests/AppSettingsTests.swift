import XCTest
@testable import CCStatusBarLib

final class AppSettingsTests: XCTestCase {
    // Store original values to restore after tests
    private var originalColorTheme: String?
    private var originalTimeout: Int?

    override func setUp() {
        super.setUp()
        // Save original values
        originalColorTheme = UserDefaults.standard.string(forKey: "colorTheme")
        originalTimeout = UserDefaults.standard.object(forKey: "sessionTimeoutMinutes") as? Int
    }

    override func tearDown() {
        // Restore original values
        if let original = originalColorTheme {
            UserDefaults.standard.set(original, forKey: "colorTheme")
        } else {
            UserDefaults.standard.removeObject(forKey: "colorTheme")
        }

        if let original = originalTimeout {
            UserDefaults.standard.set(original, forKey: "sessionTimeoutMinutes")
        } else {
            UserDefaults.standard.removeObject(forKey: "sessionTimeoutMinutes")
        }

        super.tearDown()
    }

    // MARK: - Color Theme Tests

    func testColorThemeDefaultValue() {
        UserDefaults.standard.removeObject(forKey: "colorTheme")
        XCTAssertEqual(AppSettings.colorTheme, .vibrant)
    }

    func testColorThemeSetAndGet() {
        AppSettings.colorTheme = .muted
        XCTAssertEqual(AppSettings.colorTheme, .muted)

        AppSettings.colorTheme = .warm
        XCTAssertEqual(AppSettings.colorTheme, .warm)

        AppSettings.colorTheme = .cool
        XCTAssertEqual(AppSettings.colorTheme, .cool)

        AppSettings.colorTheme = .vibrant
        XCTAssertEqual(AppSettings.colorTheme, .vibrant)
    }

    func testColorThemeInvalidRawValueFallsBackToVibrant() {
        UserDefaults.standard.set("invalid_theme", forKey: "colorTheme")
        XCTAssertEqual(AppSettings.colorTheme, .vibrant)
    }

    // MARK: - Session Timeout Tests

    func testSessionTimeoutDefaultValue() {
        UserDefaults.standard.removeObject(forKey: "sessionTimeoutMinutes")
        XCTAssertEqual(AppSettings.sessionTimeoutMinutes, 60)
    }

    func testSessionTimeoutSetAndGet() {
        AppSettings.sessionTimeoutMinutes = 30
        XCTAssertEqual(AppSettings.sessionTimeoutMinutes, 30)

        AppSettings.sessionTimeoutMinutes = 180
        XCTAssertEqual(AppSettings.sessionTimeoutMinutes, 180)
    }

    func testSessionTimeoutZeroMeansNever() {
        // 0 is a valid value meaning "Never"
        AppSettings.sessionTimeoutMinutes = 0
        XCTAssertEqual(AppSettings.sessionTimeoutMinutes, 0)
    }
}
