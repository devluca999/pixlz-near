import Foundation
import Testing
@testable import PixlMemoryKit

@Suite struct AgentIntentTests {
    @Test func savesThePartAboutATopic() {
        #expect(PixlIntent.parse("save the part about their transparent skin") == .savePart(about: "their transparent skin"))
        #expect(PixlIntent.parse("Save what it says about NEAR AI Cloud") == .savePart(about: "NEAR AI Cloud"))
        #expect(PixlIntent.parse("clip the paragraph on reproduction") == .savePart(about: "reproduction"))
        #expect(PixlIntent.parse("frogg, grab the bit about pricing please") == .savePart(about: "pricing"))
        // plain "save this" is still the whole page
        #expect(PixlIntent.parse("save this") == .savePage(note: nil))
    }

    @Test func goesToAPageThenSavesAPart() throws {
        let i = PixlIntent.parse("go to en.wikipedia.org/wiki/Glass_frog and save the part about their skin")
        #expect(i == .openAndSavePart(open: .openURL(URL(string: "https://en.wikipedia.org/wiki/Glass_frog")!), about: "their skin"))
        guard case .openAndSavePart(.openURL(let url), let about) = PixlIntent.parse("Open the Wikipedia page for glass frogs, then save the section about reproduction") else {
            Issue.record("not a compound"); return
        }
        #expect(url.absoluteString == "https://en.wikipedia.org/w/index.php?search=glass%20frogs&go=Go")
        #expect(about == "reproduction")
        // a long target in a compound is a page to find, not a question
        guard case .openAndSavePart(.open(let name, nil, true), "pricing") = PixlIntent.parse("go to the near ai cloud docs page and save the part about pricing") else {
            Issue.record("long target"); return
        }
        #expect(name == "near ai cloud docs page")
    }

    @Test func opensWikipediaByName() {
        #expect(PixlIntent.parse("open glass frogs on wikipedia") == .openURL(URL(string: "https://en.wikipedia.org/w/index.php?search=glass%20frogs&go=Go")!))
    }

    @Test func recallsSaves() {
        #expect(PixlIntent.parse("what did I save about glass frogs?") == .recall("glass frogs"))
        #expect(PixlIntent.parse("What have I saved on NEAR") == .recall("NEAR"))
        #expect(PixlIntent.parse("find my notes about pricing") == .recall("pricing"))
        #expect(PixlIntent.parse("show me my saves") == .recall(""))
        #expect(PixlIntent.parse("did I save anything about tongues") == .recall("tongues"))
        // the Notes app is still the Notes app
        #expect(PixlIntent.parse("open my notes") == .open(name: "notes", web: nil, preferWeb: false))
    }

    @Test func questionsStayQuestions() {
        #expect(PixlIntent.parse("tell me a joke") == .ask("tell me a joke"))
        #expect(PixlIntent.parse("how do I save money and keep the part I earn?") == .ask("how do I save money and keep the part I earn?"))
    }
}

@Suite struct PassageTests {
    let page = [
        "Glass frog",
        "Glass frogs are frogs of the amphibian family Centrolenidae. They live in Central and South America.",
        "Description",
        "The general background coloration of most glass frogs is primarily lime green. The abdominal skin of some members of this family is translucent, so the heart, liver and gut are visible through the transparent skin.",
        "Reproduction",
        "Glass frogs lay their eggs on leaves over streams. Males guard the eggs until the tadpoles hatch and drop into the water.",
        "See also",
        "List of frogs",
    ]

    @Test func findsTheParagraphAboutATopic() {
        #expect(PassageFinder.best(blocks: page, about: "their transparent skin")?.hasPrefix("The general background") == true)
        #expect(PassageFinder.best(blocks: page, about: "how they guard eggs")?.hasPrefix("Glass frogs lay their eggs") == true)
    }

    @Test func aHeadingMeansTheTextUnderIt() {
        #expect(PassageFinder.best(blocks: page, about: "reproduction")?.hasPrefix("Glass frogs lay their eggs") == true)
    }

    @Test func nothingWhenThePageNeverMentionsIt() {
        #expect(PassageFinder.best(blocks: page, about: "pricing") == nil)
        #expect(PassageFinder.best(blocks: page, about: "the") == nil)
    }

    @Test func longBlocksAreCutToWholeSentencesAroundTheTopic() {
        let filler = Array(repeating: "Frogs sit on leaves all day long and do nothing special at all.", count: 30)
        let block = (filler.prefix(15) + ["Their tongues strike in under a tenth of a second."] + filler.suffix(15)).joined(separator: " ")
        let p = PassageFinder.best(blocks: [block], about: "tongue strike speed", maxChars: 300)!
        #expect(p.contains("Their tongues strike"))
        #expect(p.count <= 300)
        #expect(p.hasSuffix("."))
    }

    @Test func linksToTheExactPassage() {
        let page = URL(string: "https://en.wikipedia.org/wiki/Glass_frog#Description")!
        #expect(TextFragment.link(page: page, passage: "Males guard the eggs.")?.absoluteString
                == "https://en.wikipedia.org/wiki/Glass_frog#:~:text=Males%20guard%20the%20eggs")
        let long = "The general background coloration of most glass frogs is primarily lime green, with see-through skin."
        #expect(TextFragment.link(page: page, passage: long)?.absoluteString
                == "https://en.wikipedia.org/wiki/Glass_frog#:~:text=The%20general%20background%20coloration,green%2C%20with%20see%2Dthrough%20skin")
    }

    @Test func recallRanksSavesByTopic() {
        let items = [
            HighlightItem(id: "1", text: "Pricing: $0.005 per web search", url: "https://docs.near.ai", title: "NEAR AI docs", fragmentUrl: nil),
            HighlightItem(id: "2", text: "Glass frogs have transparent skin", url: "https://en.wikipedia.org/wiki/Glass_frog", title: "Glass frog", fragmentUrl: nil),
            HighlightItem(id: "3", text: "Frogs in general", url: nil, title: "Notes", fragmentUrl: nil),
        ]
        #expect(Recall.rank(items, about: "glass frogs").map(\.id) == ["2", "3"])
        #expect(Recall.rank(items, about: "web search pricing").map(\.id) == ["1"])
        #expect(Recall.rank(items, about: "tongues").isEmpty)
        #expect(Recall.rank(items, about: "").map(\.id) == ["1", "2", "3"])
    }
}
