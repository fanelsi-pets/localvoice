import XCTest

final class LocalVoiceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUkrainianDashboardAndSettingsNavigation() throws {
        let app = configuredApplication(language: "uk", locale: "uk_UA")
        app.launch()

        XCTAssertTrue(app.staticTexts["Перевірте диктування"].waitForExistence(timeout: 10))

        let settingsButton = app.buttons["Налаштування"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        XCTAssertTrue(app.staticTexts["Інтерфейс"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Мова"].exists)
    }

    @MainActor
    func testEnglishDashboardLaunches() throws {
        let app = configuredApplication(language: "en", locale: "en_US")
        app.launch()

        XCTAssertTrue(app.staticTexts["Test your dictation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start dictation"].exists)
    }

    private func configuredApplication(language: String, locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboardingV2", "YES",
            "-IsMenuBarOnly", "NO",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppLanguagePreference", language,
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        return app
    }
}
