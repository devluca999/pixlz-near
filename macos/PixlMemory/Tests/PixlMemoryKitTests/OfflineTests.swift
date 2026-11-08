import Foundation
import Testing
@testable import PixlMemoryKit

@Suite struct OfflineTests {
    @Test func noInternetIsSaidPlainly() {
        let e = MemoryClient.error(data: Data(#"{"error":"offline","message":"no internet"}"#.utf8), status: 503)
        #expect(e.bubble == "No internet. Saving still works.")
        #expect(e.detail.contains("Nothing was sent"))
    }

    @Test func offlineAskShowsWhatYouSavedWithoutACheckCount() throws {
        let json = #"{"verdict":"offline","summary":"Offline: nothing was sent.","checks":[],"model":"m"}"#
        let v = try JSONDecoder().decode(Verification.self, from: Data(json.utf8))
        #expect(v.badge == "Offline · nothing sent" && v.checks.isEmpty)
    }
}
