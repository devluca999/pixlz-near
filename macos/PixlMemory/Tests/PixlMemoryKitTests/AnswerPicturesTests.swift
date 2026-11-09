import Foundation
import Testing
@testable import PixlMemoryKit

@Suite struct AnswerPicturesTests {
    @Test func boldNamesAreTheSubjects() {
        let a = """
        Chicago's best-known landmarks:
        1. **Willis Tower**: 108 floors, with the glass Skydeck.
        2. **Cloud Gate (The Bean)**: the mirrored sculpture in Millennium Park.
        3. **Navy Pier** – rides and lake views.
        Most are near the **Magnificent Mile**.
        """
        #expect(AnswerPictures.subjects(in: a) == ["Willis Tower", "Cloud Gate", "Navy Pier", "Magnificent Mile"])
    }

    @Test func listLeadsWhenNothingIsBold() {
        let a = "Try these:\n- Art Institute of Chicago: world-class museum\n- Wrigley Field – home of the Cubs\n- the lakefront trail: for a run"
        #expect(AnswerPictures.subjects(in: a) == ["Art Institute of Chicago", "Wrigley Field"])
    }

    @Test func noPicturesForAPlainAnswer() {
        #expect(AnswerPictures.subjects(in: "Why did the frog take the bus? Its car got **toad** away.").isEmpty)
        #expect(AnswerPictures.subjects(in: "Glass frogs are mostly lime green.").isEmpty)
    }

    @Test func readsWikipediasReply() throws {
        let json = #"{"query":{"pages":[{"pageid":1,"title":"Cloud Gate","fullurl":"https://en.wikipedia.org/wiki/Cloud_Gate","thumbnail":{"source":"https://upload.wikimedia.org/x/320px-Cloud_Gate.jpg","width":320,"height":213}}]}}"#
        let p = try #require(AnswerPictures.parse(Data(json.utf8), subject: "The Bean"))
        #expect(p.title == "Cloud Gate")
        #expect(p.page.absoluteString == "https://en.wikipedia.org/wiki/Cloud_Gate")
        // a map or logo (an SVG rendered to PNG) isn't a picture of the thing
        let svg = json.replacingOccurrences(of: "320px-Cloud_Gate.jpg", with: "320px-Map.svg.png")
        #expect(AnswerPictures.parse(Data(svg.utf8), subject: "x") == nil)
        #expect(AnswerPictures.parse(Data(#"{"batchcomplete":true}"#.utf8), subject: "x") == nil)
    }

    @Test func logosAndMapsAreNotPictures() {
        #expect(AnswerPictures.isEmblem(URL(string: "https://x/330px-Art_Institute_of_Chicago_Logo.png")!))
        #expect(AnswerPictures.isEmblem(URL(string: "https://x/330px-Flag_of_Chicago.svg.png")!))
        #expect(!AnswerPictures.isEmblem(URL(string: "https://x/330px-Navy_Pier_1190x1585.jpg")!))
    }

    @Test func searchesOnlyTheName() {
        let u = AnswerPictures.searchURL("Willis Tower").absoluteString
        #expect(u.hasPrefix("https://en.wikipedia.org/w/api.php?"))
        #expect(u.contains("gsrsearch=Willis%20Tower"))
    }
}
