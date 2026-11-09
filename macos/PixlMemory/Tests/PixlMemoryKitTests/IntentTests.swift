import Foundation
import Testing
@testable import PixlMemoryKit

@Suite struct IntentTests {
    @Test(arguments: [
        ("open spotify", "spotify", false), ("Open Spotify.", "Spotify", false), ("hey frogg, can you open spotify please", "spotify", false),
        ("launch Notes", "Notes", false), ("open spotify in a new tab", "spotify", true), ("go to youtube in the browser", "youtube", true),
        ("open the calculator app", "calculator", false), ("take me to github", "github", false), ("pull up gmail", "gmail", false),
    ])
    func opensAnApp(_ q: String, _ name: String, _ web: Bool) {
        guard case .open(let n, _, let preferWeb) = PixlIntent.parse(q) else { Issue.record("\(q) → \(PixlIntent.parse(q))"); return }
        #expect(n == name)
        #expect(preferWeb == web)
    }

    @Test func knownSitesComeWithTheirAddress() {
        #expect(PixlIntent.parse("open spotify") == .open(name: "spotify", web: URL(string: "https://open.spotify.com"), preferWeb: false))
        #expect(PixlIntent.parse("open Xcode") == .open(name: "Xcode", web: nil, preferWeb: false))
    }

    @Test(arguments: [("go to github.com", "https://github.com"), ("open https://near.org/blog", "https://near.org/blog"),
                      ("visit news.ycombinator.com", "https://news.ycombinator.com"), ("Open docs.near.ai/cloud", "https://docs.near.ai/cloud")])
    func opensAnAddress(_ q: String, _ url: String) {
        #expect(PixlIntent.parse(q) == .openURL(URL(string: url)!))
    }

    @Test func savesThePage() {
        #expect(PixlIntent.parse("save this") == .savePage(note: nil))
        #expect(PixlIntent.parse("Save this article") == .savePage(note: nil))
        #expect(PixlIntent.parse("remember this page") == .savePage(note: nil))
        #expect(PixlIntent.parse("save a reference") == .savePage(note: nil))
        #expect(PixlIntent.parse("save this to my notes") == .savePage(note: nil))
        #expect(PixlIntent.parse("save this as Glass frog research") == .savePage(note: "Glass frog research"))
        #expect(PixlIntent.parse("bookmark this: read before Friday") == .savePage(note: "read before Friday"))
    }

    @Test func playsAndSearches() {
        #expect(PixlIntent.parse("play Daft Punk on Spotify") == .play(query: "Daft Punk", app: "spotify"))
        #expect(PixlIntent.parse("google glass frogs") == .searchInBrowser("glass frogs"))
    }

    @Test(arguments: ["tell me a joke", "what's the weather in Lisbon?", "how do frogs breathe",
                      "open my notes and find the bit about frogs that I liked", "Is it raining?", "who won the game last night"])
    func everythingElseIsAQuestion(_ q: String) {
        #expect(PixlIntent.parse(q) == .ask(q))
    }

    @Test func webAddresses() {
        #expect(PixlIntent.webAddress("spotify") == nil)
        #expect(PixlIntent.webAddress("spotify.com") == URL(string: "https://spotify.com"))
        #expect(PixlIntent.webAddress("two words.com") == nil)
    }
}

@Suite struct AppFinderTests {
    func fixture(_ names: [String]) throws -> AppFinder {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        for n in names { try FileManager.default.createDirectory(at: dir.appendingPathComponent(n + ".app"), withIntermediateDirectories: true) }
        return AppFinder(folders: [dir])
    }

    @Test func findsByNameAliasAndPrefix() throws {
        let f = try fixture(["Spotify", "Visual Studio Code", "Google Chrome", "Notes", "Notion", "System Settings"])
        #expect(f.find("spotify")?.lastPathComponent == "Spotify.app")
        #expect(f.find("SPOTIFY")?.lastPathComponent == "Spotify.app")
        #expect(f.find("vs code")?.lastPathComponent == "Visual Studio Code.app")
        #expect(f.find("chrome")?.lastPathComponent == "Google Chrome.app")
        #expect(f.find("notes")?.lastPathComponent == "Notes.app")    // exact beats Notion
        #expect(f.find("settings")?.lastPathComponent == "System Settings.app")
        #expect(f.find("netflix") == nil)
        #expect(f.find("no") == nil)                                   // too short to guess
    }
}
