import XCTest
@testable import WolfWave

nonisolated final class BundleInstallMethodTests: XCTestCase {

    // MARK: - DMG / Non-Homebrew Paths

    @MainActor func testApplicationsPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath("/Applications/WolfWave.app"))
    }

    @MainActor func testDownloadsPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath("/Users/alice/Downloads/WolfWave.app"))
    }

    @MainActor func testUserApplicationsPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath("/Users/alice/Applications/WolfWave.app"))
    }

    @MainActor func testEmptyPathIsNotHomebrew() {
        XCTAssertFalse(Bundle.isHomebrewPath(""))
    }

    // MARK: - Apple Silicon Homebrew

    @MainActor func testAppleSiliconCaskroomIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/opt/homebrew/Caskroom/wolfwave/1.0.0/WolfWave.app"))
    }

    @MainActor func testAppleSiliconCellarIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/opt/homebrew/Cellar/something/1.0/bin"))
    }

    // MARK: - Intel Homebrew

    @MainActor func testIntelCaskroomIsHomebrew() {
        // Regression guard: previously misclassified as DMG install.
        XCTAssertTrue(Bundle.isHomebrewPath("/usr/local/Caskroom/wolfwave/1.0.0/WolfWave.app"))
    }

    @MainActor func testIntelCellarIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/usr/local/Cellar/something/1.0/bin"))
    }

    // MARK: - Custom Prefix

    @MainActor func testCustomHomebrewPrefixIsHomebrew() {
        XCTAssertTrue(Bundle.isHomebrewPath("/Users/alice/Homebrew/Caskroom/wolfwave/1.0.0/WolfWave.app"))
    }

    // MARK: - Bundle.main accessor compiles

    @MainActor func testMainBundleAccessorReturnsBool() {
        _ = Bundle.main.isHomebrewInstall
    }
}
