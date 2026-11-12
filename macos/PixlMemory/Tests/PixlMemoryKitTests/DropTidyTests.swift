import Foundation
import Testing
@testable import PixlMemoryKit

struct DropTidyTests {
    let original = "hey so basically i wanted to reach out"
    let polished = "Hey, I wanted to reach out."
    let rest = "\n\nThe checklist is attached."

    func tidied(_ value: String) -> String? {
        DropTidy.range(in: value, original: original, dropped: polished).map { (value as NSString).replacingCharacters(in: $0, with: polished) }
    }

    @Test func aDropInsideTheOriginalReplacesIt() {
        // what TextEdit does with a drop five characters into the selection
        #expect(tidied("hey s" + polished + "o basically i wanted to reach out" + rest) == polished + rest)
    }

    @Test func aDropRightBeforeOrAfterTheOriginalReplacesIt() {
        #expect(tidied("Hi Ana,\n" + polished + original + rest) == "Hi Ana,\n" + polished + rest)
        #expect(tidied("Hi Ana,\n" + original + polished + rest) == "Hi Ana,\n" + polished + rest)
    }

    @Test func aDropElsewhereIsLeftAlone() {
        #expect(tidied(original + rest + "\n" + polished) == nil)          // a new paragraph, on purpose
        #expect(tidied("hey s" + polished + "o basically i changed this" + rest) == nil)   // the original was edited meanwhile
        #expect(tidied(original + rest) == nil)                             // nothing was dropped
    }

    @Test func twoPossibleReadingsAreLeftAlone() {
        // "aa" split by "X" in "aaXaa" could be before, after or around the drop
        #expect(DropTidy.range(in: "aaXaa", original: "aa", dropped: "X") == nil)
        #expect(DropTidy.range(in: "", original: "", dropped: "X") == nil)
    }

    @Test func countsTheWayAccessibilityDoes() {
        // emoji are two UTF-16 units: the range must still cover exactly original + dropped
        let v = "🐸 ok 🐸 hey s" + polished + "o basically i wanted to reach out 🐸"
        let r = DropTidy.range(in: v, original: original, dropped: polished)
        #expect(r == NSRange(location: 9, length: (original as NSString).length + (polished as NSString).length))
    }
}
