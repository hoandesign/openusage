import XCTest
@testable import OpenUsage

final class MuseAuthStoreTests: XCTestCase {
    func testDefaultCredentialAndSessionsPathsUseHomeConfigLayout() {
        let store = MuseAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }
        )

        XCTAssertEqual(store.credentialPath, "/Users/test/.config/muse/auth.json")
        XCTAssertEqual(store.sessionsRoot, "/Users/test/.local/share/muse/sessions")
    }

    func testHonorsMuseAuthPathAndXDGOverrides() {
        let store = MuseAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment([
                "MUSE_AUTH_PATH": "/custom/auth.json",
                "XDG_DATA_HOME": "/xdg/data"
            ]),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }
        )

        XCTAssertEqual(store.credentialPath, "/custom/auth.json")
        XCTAssertEqual(store.sessionsRoot, "/xdg/data/muse/sessions")
    }

    func testXDGConfigHomeResolvesAuthWhenMuseAuthPathUnset() {
        let store = MuseAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["XDG_CONFIG_HOME": "/xdg/config"]),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }
        )

        XCTAssertEqual(store.credentialPath, "/xdg/config/muse/auth.json")
    }

    func testCredentialFootprintFromEnvAuthFileOrSessions() {
        let home = URL(fileURLWithPath: "/Users/test")
        let authPath = home.appendingPathComponent(".config/muse/auth.json").path
        let sessions = home.appendingPathComponent(".local/share/muse/sessions").path

        XCTAssertFalse(
            MuseAuthStore(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home })
                .hasCredentialFootprint()
        )
        XCTAssertTrue(
            MuseAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["META_API_KEY": "tok"]),
                homeDirectory: { home }
            ).hasCredentialFootprint()
        )
        XCTAssertTrue(
            MuseAuthStore(
                files: FakeFiles([authPath: #"{"providers":{}}"#]),
                environment: FakeEnvironment(),
                homeDirectory: { home }
            ).hasCredentialFootprint()
        )
        XCTAssertTrue(
            MuseAuthStore(
                files: FakeFiles([sessions: ""]),
                environment: FakeEnvironment(),
                homeDirectory: { home }
            ).hasCredentialFootprint()
        )
    }
}
