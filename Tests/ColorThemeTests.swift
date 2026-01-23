import XCTest
@testable import CCStatusBarLib

final class ColorThemeTests: XCTestCase {
    // MARK: - Raw Value Tests

    func testRawValues() {
        XCTAssertEqual(ColorTheme.vibrant.rawValue, "vibrant")
        XCTAssertEqual(ColorTheme.muted.rawValue, "muted")
        XCTAssertEqual(ColorTheme.warm.rawValue, "warm")
        XCTAssertEqual(ColorTheme.cool.rawValue, "cool")
    }

    func testInitFromRawValue() {
        XCTAssertEqual(ColorTheme(rawValue: "vibrant"), .vibrant)
        XCTAssertEqual(ColorTheme(rawValue: "muted"), .muted)
        XCTAssertEqual(ColorTheme(rawValue: "warm"), .warm)
        XCTAssertEqual(ColorTheme(rawValue: "cool"), .cool)
        XCTAssertNil(ColorTheme(rawValue: "invalid"))
    }

    // MARK: - Display Name Tests

    func testDisplayNames() {
        XCTAssertEqual(ColorTheme.vibrant.displayName, "Vibrant")
        XCTAssertEqual(ColorTheme.muted.displayName, "Muted")
        XCTAssertEqual(ColorTheme.warm.displayName, "Warm")
        XCTAssertEqual(ColorTheme.cool.displayName, "Cool")
    }

    // MARK: - CaseIterable Tests

    func testAllCasesCount() {
        XCTAssertEqual(ColorTheme.allCases.count, 4)
    }

    func testAllCasesContainsAllThemes() {
        let allCases = ColorTheme.allCases
        XCTAssertTrue(allCases.contains(.vibrant))
        XCTAssertTrue(allCases.contains(.muted))
        XCTAssertTrue(allCases.contains(.warm))
        XCTAssertTrue(allCases.contains(.cool))
    }

    // MARK: - Color Property Tests (verify colors are defined)

    func testColorsAreDefined() {
        for theme in ColorTheme.allCases {
            // Verify each theme has non-nil colors
            XCTAssertNotNil(theme.redColor, "\(theme.displayName) should have redColor")
            XCTAssertNotNil(theme.yellowColor, "\(theme.displayName) should have yellowColor")
            XCTAssertNotNil(theme.greenColor, "\(theme.displayName) should have greenColor")
            XCTAssertNotNil(theme.whiteColor, "\(theme.displayName) should have whiteColor")
        }
    }
}
