import Testing
@testable import PixlzCore

@Test func versionIsSet() {
    #expect(!PixlzCore.version.isEmpty)
}
