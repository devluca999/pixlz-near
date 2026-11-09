import AppKit

/// The C8 pixel icons (design/explorations/c3/glass.js): 12 × 12, ink outline on paper with one
/// token accent; on dark glass ink and paper swap. Drawn nearest-neighbour at 2× (24 pt).
@MainActor
public enum BubbleIcons {
    static let grids: [String: [String]] = [
        "ask": [".kkkkkkkkkk.", "kaaaaaaaaaak", "kaaakkkkaaak", "kaakkaakkaak", "kaaaaaakkaak", "kaaaaakkaaak", "kaaaakkaaaak",
                "kaaaaaaaaaak", "kaaaakkaaaak", ".kkkakkkkkk.", "...kak......", "...kk......."],
        "polish": [".....k......", "....kak.....", "....kak.....", "..kkaaakk...", ".kaaawaaak..", "..kkaaakk...", "....kak...k.",
                   "....kak..kak", ".....k....k.", ".k..........", "kak.........", ".k.........."],
        "memory": [".kkkkkkkk...", ".kakwwwwkk..", ".kakwwwwkwk.", ".kakwwwwkkkk", ".kakwkkkkwwk", ".kakwwwwwwwk", ".kkkwkkkkkwk",
                   ".kwwwwwwwwwk", ".kwkkkkkkwwk", ".kwwwwwwwwwk", ".kkkkkkkkkkk", "............"],
        "wallet": ["...kkkkkk...", "..kaaaaaak..", ".kaaaaaaaak.", "kaakaaaakabk", "kaakkaaakabk", "kaakakaakabk", "kaakaakakabk",
                   "kaakaaakkabk", "kaakaaaakabk", ".kbaaaaaabk.", "..kbbbbbbk..", "...kkkkkk..."],
        "send": ["..kkkkkkkk..", "..kwwwwwwk..", "..kwwaawwk..", "..kwaaaawk..", "..kaaaaaak..", "..kwwaawwk..", "..kwwaawwk..",
                 "..kwwaawwk..", "..kwwwwwwk..", "..kkkkkkkk..", "..kwwkkwwk..", "..kkkkkkkk.."],
        "more": ["............", "............", "............", "............", "............", ".kk..kk..kk.", ".kk..kk..kk.",
                 "............", "............", "............", "............", "............"],
        "settings": [".....kk.....", "..k.kaak.k..", ".kakaaaakak.", "..kaakkaak..", ".kaakwwkaak.", "kaakwwwwkaak", "kaakwwwwkaak",
                     ".kaakwwkaak.", "..kaakkaak..", ".kakaaaakak.", "..k.kaak.k..", ".....kk....."],
        "search": ["..kkkk......", ".kwwwwk.....", "kwwaawwk....", "kwaawwwk....", "kwawwwwk....", "kwwwwwwk....", ".kwwwwk.....",
                   "..kkkkkk....", "......kak...", ".......kak..", "........kak.", ".........kk."],
        "info": ["...kkkkkk...", "..kaaaaaak..", ".kaaawwaaak.", "kaaaawwaaaak", "kaaaaaaaaaak", "kaaaawwaaaak", "kaaaawwaaaak",
                 "kaaaawwaaaak", "kaaaawwaaaak", ".kaaawwaaak.", "..kaaaaaak..", "...kkkkkk..."],
        "check": ["...kkkkkk...", "..kaaaaaak..", ".kaaaaaawak.", "kaaaaaawwaak", "kaaaaawwaaak", "kawaawwaaaak", "kawwwwaaaaak",
                  "kaawwaaaaaak", "kaaaaaaaaaak", ".kaaaaaaaak.", "..kaaaaaak..", "...kkkkkk..."],
        "warn": [".....kk.....", "....kaak....", "....kaak....", "...kaaaak...", "...kawwak...", "..kaawwaak..", "..kaawwaak..",
                 ".kaaawwaaak.", ".kaaaaaaaak.", "kaaaawwaaaak", "kaaaaaaaaaak", "kkkkkkkkkkkk"],
        "hide": ["............", "............", "..kkkkkkkk..", ".kwwwwwwwwk.", "kwwkkwwkkwwk", "kwwkkwwkkwwk", "kwwwwwwwwwwk",
                 ".kwwwwwwwwk.", "..kkkkkkkk..", "...k....k...", "..k......k..", "............"],
    ]
    /// Token accents (tokens/colors.css): frogg for Ask, flame-2 for Polish and Wallet, dew for Memory, dragon for Send.
    static let accents: [String: [String]] = [
        "ask": ["#7CD93A"], "polish": ["#FFD23F"], "memory": ["#2F6FE0"], "wallet": ["#FFD23F", "#FF8A1F"],
        "send": ["#2FB3A6"], "more": [], "settings": ["#9AA295"], "hide": [], "search": ["#86C5F0"],
        "info": ["#2F6FE0"], "check": ["#7CD93A"], "warn": ["#FF8A1F"],
    ]

    public static var names: [String] { grids.keys.sorted() }

    /// The icon at `scale` pixels per icon pixel (2 = 24 pt). Nil for an unknown name.
    public static func image(_ name: String, dark: Bool, scale: CGFloat = 2) -> NSImage? {
        guard let grid = grids[name] else { return nil }
        let a = accents[name] ?? []
        let colors: [Character: String?] = ["k": dark ? "#FFFBF2" : "#1B2A1A", "w": dark ? "#1B2A1A" : "#FFFBF2",
                                            "a": a.first, "b": a.count > 1 ? a[1] : a.first]
        return NSImage(size: NSSize(width: 12 * scale, height: 12 * scale), flipped: true) { _ in
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let hex = colors[ch] ?? nil else { continue }
                    let c = RGB(hex: hex)
                    NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
                    NSRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale).fill()
                }
            }
            return true
        }
    }
}
