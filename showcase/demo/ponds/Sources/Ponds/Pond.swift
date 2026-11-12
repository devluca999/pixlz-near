/// A pond with some lily pads and the frogs sitting on them (demo code for the Pixlz video).
public struct Pond {
    public var pads: Int
    public var frogs: Int
    public init(pads: Int, frogs: Int) { self.pads = pads; self.frogs = frogs }
    /// Every frog gets a pad; spare frogs wait in the reeds.
    public var seated: Int { min(pads, frogs) }
    public var waiting: Int { max(0, frogs - pads) }
    public mutating func addPads(_ n: Int) { pads += max(0, n) }
}
