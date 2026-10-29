import Testing
@testable import FoldGit

struct AppVersionTests {
    @Test func parsesReleaseTags() {
        #expect(AppVersion("v0.1.1")?.description == "0.1.1")
        #expect(AppVersion("1.2.0-beta.1")?.description == "1.2.0")
        #expect(AppVersion("release") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func comparesComponentsNumerically() throws {
        let version = { (text: String) throws -> AppVersion in try #require(AppVersion(text)) }
        #expect(try version("0.9.0") < version("0.10.0"))
        #expect(try version("0.1.1") < version("v0.2.0"))
        #expect(try !(version("1.0.0") < version("1.0")))
        #expect(try version("1.0") == version("1.0.0"))
    }
}
