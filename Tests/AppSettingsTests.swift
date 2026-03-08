import XCTest
@testable import CCStatusBarLib

final class AppSettingsTests: XCTestCase {
    // Use the same suite as AppSettings
    private static let bundleID = "com.ccstatusbar.app"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.bundleID) ?? UserDefaults.standard }

    // Store original values to restore after tests
    private var originalColorTheme: String?
    private var originalTimeout: Int?
    private var originalAlertSoundPath: String?
    private var originalAlertsEnabled: Bool?
    private var originalAlertCommand: String?

    override func setUp() {
        super.setUp()
        // Save original values
        originalColorTheme = defaults.string(forKey: "colorTheme")
        originalTimeout = defaults.object(forKey: "sessionTimeoutMinutes") as? Int
        originalAlertSoundPath = defaults.string(forKey: "alertSoundPath")
        originalAlertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool
        originalAlertCommand = defaults.string(forKey: "alertCommand")
    }

    override func tearDown() {
        // Restore original values
        if let original = originalColorTheme {
            defaults.set(original, forKey: "colorTheme")
        } else {
            defaults.removeObject(forKey: "colorTheme")
        }

        if let original = originalTimeout {
            defaults.set(original, forKey: "sessionTimeoutMinutes")
        } else {
            defaults.removeObject(forKey: "sessionTimeoutMinutes")
        }

        if let original = originalAlertSoundPath {
            defaults.set(original, forKey: "alertSoundPath")
        } else {
            defaults.removeObject(forKey: "alertSoundPath")
        }

        if let original = originalAlertsEnabled {
            defaults.set(original, forKey: "alertsEnabled")
        } else {
            defaults.removeObject(forKey: "alertsEnabled")
        }

        if let original = originalAlertCommand {
            defaults.set(original, forKey: "alertCommand")
        } else {
            defaults.removeObject(forKey: "alertCommand")
        }

        super.tearDown()
    }

    // MARK: - Color Theme Tests

    func testColorThemeDefaultValue() {
        defaults.removeObject(forKey: "colorTheme")
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
        defaults.set("invalid_theme", forKey: "colorTheme")
        XCTAssertEqual(AppSettings.colorTheme, .vibrant)
    }

    // MARK: - Session Timeout Tests

    func testSessionTimeoutDefaultValue() {
        defaults.removeObject(forKey: "sessionTimeoutMinutes")
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

    // MARK: - Alert Sound Initialization Tests

    func testInitializeDefaultAlertSoundIfNeeded_setsDefaultWhenUnset() {
        defaults.removeObject(forKey: "alertSoundPath")

        AppSettings.initializeDefaultAlertSoundIfNeeded(fileExists: { _ in true })

        XCTAssertEqual(AppSettings.alertSoundPath, AppSettings.defaultAlertSoundPath)
    }

    func testInitializeDefaultAlertSoundIfNeeded_keepsExistingSetting() {
        AppSettings.alertSoundPath = "beep"
        AppSettings.initializeDefaultAlertSoundIfNeeded(fileExists: { _ in false })
        XCTAssertEqual(AppSettings.alertSoundPath, "beep")

        AppSettings.alertSoundPath = "/tmp/custom-alert.aiff"
        AppSettings.initializeDefaultAlertSoundIfNeeded(fileExists: { _ in false })
        XCTAssertEqual(AppSettings.alertSoundPath, "/tmp/custom-alert.aiff")
    }

    func testInitializeDefaultAlertSoundIfNeeded_fallsBackToBeepWhenDefaultMissing() {
        defaults.removeObject(forKey: "alertSoundPath")

        AppSettings.initializeDefaultAlertSoundIfNeeded(fileExists: { _ in false })

        XCTAssertEqual(AppSettings.alertSoundPath, "beep")
    }

    func testInitializeDefaultAlertSoundIfNeeded_treatsEmptyStringAsUnset() {
        defaults.set("", forKey: "alertSoundPath")

        AppSettings.initializeDefaultAlertSoundIfNeeded(fileExists: { _ in true })

        XCTAssertEqual(AppSettings.alertSoundPath, AppSettings.defaultAlertSoundPath)
    }

    // MARK: - Alert Command Tests

    func testAlertsEnabledDefaultsToFalse() {
        defaults.removeObject(forKey: "alertsEnabled")
        XCTAssertFalse(AppSettings.alertsEnabled)
    }

    func testAlertCommandSetAndGet() {
        AppSettings.alertCommand = "echo hello"
        XCTAssertEqual(AppSettings.alertCommand, "echo hello")
        XCTAssertTrue(AppSettings.isAlertCommandConfigured)
    }

    func testEmptyAlertCommandIsTreatedAsUnconfigured() {
        AppSettings.alertCommand = "   "
        XCTAssertFalse(AppSettings.isAlertCommandConfigured)
        XCTAssertFalse(AppSettings.isAlertCommandEnabled)
    }

    func testAlertCommandEnabledRequiresCommand() {
        AppSettings.alertsEnabled = true
        AppSettings.alertCommand = nil
        XCTAssertFalse(AppSettings.isAlertCommandEnabled)

        AppSettings.alertCommand = "echo ready"
        XCTAssertTrue(AppSettings.isAlertCommandEnabled)
    }
}
