import AppKit
import Testing
@testable import PixlMemoryKit

@MainActor
@Suite struct ScreenSizeTests {
    @Test func aTallCardScrollsItsBodyAndKeepsItsButtons() {
        let before = PixlCard.maxBodyHeight
        PixlCard.maxBodyHeight = 200   // a short laptop screen with big text
        let card = PixlCard(title: "Ask", icon: nil, look: .init(glass: false, variant: .light, dim: 1))
        PixlCard.maxBodyHeight = before
        for i in 0..<30 { card.stack.addArrangedSubview(card.text("A long answer, line \(i).")) }
        card.setFooter([PixelButton(title: "Save answer", primary: false) {}])
        card.fit()
        #expect(card.frame.height < 320, "card is \(card.frame.height) pt tall")
        #expect(card.bodyScroll.frame.height <= 200)
        #expect(card.bodyScroll.documentView!.frame.height > 400)   // the rest is a scroll away
    }

    @Test func aShortCardDoesNotScroll() {
        let card = PixlCard(title: "Ask", icon: nil, look: .init(glass: false, variant: .light, dim: 1))
        card.stack.addArrangedSubview(card.text("One line."))
        card.fit()
        #expect(abs(card.bodyScroll.frame.height - card.bodyScroll.documentView!.frame.height) < 1)
    }

    @Test func aPixlOnAnUnpluggedDisplayIsOffScreen() {
        let laptop = CGRect(x: 0, y: 25, width: 1470, height: 900)
        let monitor = CGRect(x: 1470, y: 0, width: 2560, height: 1415)
        let sprite = CGSize(width: 100, height: 80)
        let onMonitor = CGPoint(x: 2400, y: 900)
        #expect(Perch.isOnScreen(foot: onMonitor, sprite: sprite, screens: [laptop, monitor]))
        #expect(!Perch.isOnScreen(foot: onMonitor, sprite: sprite, screens: [laptop]))   // monitor unplugged
        #expect(Perch.isOnScreen(foot: CGPoint(x: 1460, y: 500), sprite: sprite, screens: [laptop]))  // half over the edge is fine
    }
}
