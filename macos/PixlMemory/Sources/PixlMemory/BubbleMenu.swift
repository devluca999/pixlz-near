import AppKit
import PixlMemoryKit
import PixlzCore
import PixlBridge

/// The C8 option-bubble menu, its "More" list, and the cards its slots open (SPEC §11.2).
/// Owns its panels; AppController calls `open`, `close`, `pop`, and `step` from its clock.
@MainActor
final class BubbleMenu {
    unowned let app: AppController
    var panel: KeyPanel?
    var view: OptionBubblesView?
    var listPanel: KeyPanel?
    var list: ListMenuView?
    var cardPanel: KeyPanel?
    var direction: BubbleMenuModel.Direction = .up
    var openedFoot: CGPoint?
    var previousApp: NSRunningApplication?
    var wallet: WalletInfo?
    var monitors: [Any] = []
    /// Bumped whenever a card opens or closes, so a slow fetch never pops up a stale card.
    var cardGen = 0

    init(app: AppController) { self.app = app }

    var isOpen: Bool { view.map { $0.phase != .closed } ?? false }
    var isAnimating: Bool { view?.isAnimating ?? false }
    var ui: PixlUI { app.ui }

    // MARK: looks (legibility: text surfaces dim enough for 4.5:1 over anything)

    var prefersDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    var iconLook: SurfaceView.Look { .icon(prefersDark: prefersDark) }
    var labelLook: SurfaceView.Look { .text(designFill: prefersDark ? 0.66 : 0.62, prefersDark: prefersDark) }
    var cardLook: SurfaceView.Look { .text(designFill: prefersDark ? 0.42 : 0.26, prefersDark: prefersDark) }
    var accent: NSColor { let c = RGB(hex: ui.accent); return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    // MARK: geometry (top-left global coordinates)

    /// Where the bubbles puff out of: the top of the Pixl's head.
    var head: CGPoint? {
        guard let foot = app.foot else { return nil }
        let art = FroggArt.shared.size(app.frogg.frameName)
        return CGPoint(x: foot.x, y: foot.y - art.height * app.scale + 5 * app.scale)
    }

    /// The caret and the selection being polished: bubbles never cover them.
    func avoidRects() -> [CGRect] {
        guard AX.trusted, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return app.selfTestAvoid }
        return AX.selectionBounds(pid: pid) + app.selfTestAvoid
    }

    // MARK: open / close

    func open(trigger: String) {
        guard !app.userHidden, head != nil else { return }
        closeList()
        closeCard()  // also invalidates any card still fetching
        // Accessibility first (instant). In a browser where it can't see the selection (rich
        // editors, Google Docs), ask the extension through the bridge, briefly.
        if app.readSelection() == nil, AX.isChromium(NSWorkspace.shared.frontmostApplication), app.bridge.connected {
            let front = NSWorkspace.shared.frontmostApplication
            app.bridge.selection { [weak self] reply in
                guard let self else { return }
                if let reply, let text = reply.text {
                    self.app.setWebSelection(text, app: front, title: reply.title)
                }
                self.openNow(trigger: trigger)
            }
            return
        }
        openNow(trigger: trigger)
    }

    private func openNow(trigger: String) {
        guard !app.userHidden, let head else { return }
        let slots = BubbleMenuModel.slots(selection: app.pendingSelection != nil, peer: nil, walletSub: wallet?.short)
        let screen = app.screensTopLeft.first { $0.minX <= head.x && head.x <= $0.maxX } ?? app.screensTopLeft.first ?? .zero
        let placement = BubbleMenuModel.place(count: slots.count, head: head, radius: BubbleMenuModel.radius(scale: app.scale),
                                              screen: screen, avoid: avoidRects())
        direction = placement.direction
        // a panel around the head and every bubble + label footprint
        let box = placement.centers.map(BubbleMenuModel.footprint).reduce(CGRect(origin: head, size: .zero)) { $0.union($1) }
            .insetBy(dx: -24, dy: -24)
        let local = { (p: CGPoint) in CGPoint(x: p.x - box.minX, y: p.y - box.minY) }
        let v = OptionBubblesView(frame: NSRect(origin: .zero, size: box.size), slots: slots, head: local(head),
                                  centers: placement.centers.map(local), look: iconLook, labelLook: labelLook)
        v.accent = accent
        v.onSelect = { [weak self] slot in self?.selected(slot) }
        v.onCancel = { [weak self] in self?.close(reason: "esc") }
        let p = panel ?? KeyPanel(size: box.size)
        p.level = .popUpMenu
        p.contentView = v
        p.setFrame(Perch.toAppKit(box, primaryHeight: app.primaryHeight), display: false)
        p.onCancel = { [weak self] in self?.close(reason: "esc") }
        panel = p
        view = v
        openedFoot = app.foot
        previousApp = NSWorkspace.shared.frontmostApplication
        p.alphaValue = 1
        p.makeKeyAndOrderFront(nil)  // keyboard: arrows, Return, Esc (the panel never activates the app)
        p.makeFirstResponder(v)
        v.open(at: app.now)
        app.cancelAnimations()
        app.frogg.frameName = ui.menuFace  // the poke is cut short: curious face while the menu is open
        Debug.log("bubbles open via \(trigger) slots=\(slots.map(\.id)) direction=\(placement.direction) offset=\(Int(placement.offset.dx)),\(Int(placement.offset.dy)) look=\(iconLook.glass ? "glass" : "paper")/\(iconLook.variant) labelDim=\(labelLook.dim)")
        watchOutside()
        app.startClock()
    }

    /// Esc, click-away: reverse stagger back into the head.
    func close(reason: String) {
        closeList()
        guard let v = view, v.phase != .closed else { return }
        Debug.log("bubbles close (\(reason))")
        v.close(at: app.now)
        stopWatching()
        app.startClock()
    }

    /// A drag on the Pixl started: all bubbles pop at once.
    func pop() {
        closeList()
        guard let v = view, v.phase != .closed else { return }
        Debug.log("bubbles pop (drag)")
        v.pop(at: app.now)
        stopWatching()
        app.startClock()
    }

    /// Called every display frame while open or animating.
    func step(_ t: TimeInterval) {
        guard let v = view else { return }
        // follow the Pixl if it moves while the menu is open
        if let was = openedFoot, let now = app.foot, (was.x != now.x || was.y != now.y), let p = panel {
            p.setFrameOrigin(NSPoint(x: p.frame.minX + (now.x - was.x), y: p.frame.minY - (now.y - was.y)))
            listPanel.map { $0.setFrameOrigin(NSPoint(x: $0.frame.minX + (now.x - was.x), y: $0.frame.minY - (now.y - was.y))) }
            openedFoot = now
        }
        v.advance(to: t)
        if v.phase == .closed { teardown() }
    }

    func teardown() {
        panel?.orderOut(nil)
        view = nil
        openedFoot = nil
        if app.mode == .perched, !app.moving { app.backToIdle() }
        // hand the keyboard back to the app you were in
        if cardPanel == nil, listPanel == nil, let prev = previousApp, prev != NSRunningApplication.current {
            prev.activate()
        }
    }

    func watchOutside() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "click away") }
        }) { monitors.append(m) }
    }

    func stopWatching() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: slots

    func selected(_ slot: BubbleMenuModel.Slot) {
        Debug.log("slot \(slot.id)")
        switch slot.id {
        case "polish": showPolishList()
        case "ask": close(reason: "ask"); showAsk()
        case "memory": close(reason: "memory"); showMemory()
        case "wallet": close(reason: "wallet"); showWallet()
        case "more": showMore()
        default: close(reason: slot.id)
        }
    }

    func showPolishList() {
        let rows = app.instructions.enumerated().map { i, ins in
            ListMenuView.Row(id: "polish.\(i)", title: ins.title, icon: i == 0 ? "polish" : nil)
        }
        showList(rows, near: "polish") { [weak self] row in
            guard let self, let i = Int(row.id.dropFirst("polish.".count)) else { return }
            self.close(reason: "polish")
            self.app.polish(i)
        }
    }

    /// More: the other bubbles fold away and the mini menu grows from the More bubble.
    func showMore() {
        var rows = [ListMenuView.Row(id: "ask", title: "Ask", icon: "ask", trailing: "⌘K"),
                    ListMenuView.Row(id: "memory", title: "Memory", icon: "memory"),
                    ListMenuView.Row(id: "wallet", title: "Wallet", icon: "wallet", trailing: wallet?.short),
                    ListMenuView.Row(id: "send", title: "Send to device", icon: "send", enabled: false),
                    ListMenuView.Row(id: "focus", title: app.focusUntil == nil ? "Focus for 25 min" : "Stop focus", icon: nil),
                    ListMenuView.Row(id: "signature", title: "Do your thing", icon: nil, trailing: ui.signature),
                    ListMenuView.Row(id: "settings", title: "Pixl settings", icon: "settings", trailing: "⌃⌥P"),
                    ListMenuView.Row(id: "hide", title: "Hide for now", icon: "hide", trailing: "⌃⌥H")]
        if app.pendingSelection != nil { rows.insert(ListMenuView.Row(id: "polish", title: "Polish selection", icon: "polish"), at: 0) }
        // fold the other bubbles in; the list takes over
        view?.close(at: app.now)
        showList(rows, near: "more") { [weak self] row in self?.moreChosen(row.id) }
    }

    func moreChosen(_ id: String) {
        closeList()
        switch id {
        case "polish": showPolishListFromMore()
        case "ask": showAsk()
        case "memory": showMemory()
        case "wallet": showWallet()
        case "focus": app.focusUntil == nil ? app.startFocus(minutes: 25) : app.endFocus(completed: false)
        case "signature": app.signature()
        case "settings": app.toggleMiniMenu()
        case "hide": app.toggleHidden()
        default: break
        }
    }

    func showPolishListFromMore() {
        let rows = app.instructions.enumerated().map { i, ins in ListMenuView.Row(id: "polish.\(i)", title: ins.title, icon: i == 0 ? "polish" : nil) }
        showList(rows, near: nil) { [weak self] row in
            guard let self, let i = Int(row.id.dropFirst("polish.".count)) else { return }
            self.closeList()
            self.app.polish(i)
        }
    }

    func showList(_ rows: [ListMenuView.Row], near slotID: String?, onSelect: @escaping @MainActor (ListMenuView.Row) -> Void) {
        closeList()
        let l = ListMenuView(rows: rows, look: cardLook)
        l.onSelect = onSelect
        l.onCancel = { [weak self] in self?.closeList(); self?.close(reason: "esc") }
        let p = KeyPanel(size: l.frame.size)
        p.level = .popUpMenu
        p.contentView = l
        p.onCancel = l.onCancel
        // grow from the chosen bubble (or beside the Pixl), fully on screen and off the selection
        var anchor = app.froggBox
        if let id = slotID, let v = view, let i = v.slots.firstIndex(where: { $0.id == id }), let vp = panel {
            let c = v.centers[i]
            anchor = Placement.screenRect(of: NSRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44),
                                          inFlippedViewOfHeight: v.bounds.height, windowOrigin: vp.frame.origin)
        }
        var r = CGRect(x: anchor.midX - l.frame.width / 2, y: anchor.maxY + 8, width: l.frame.width, height: l.frame.height)
        if r.maxY > app.froggScreen.maxY - 8 { r.origin.y = anchor.minY - l.frame.height - 8 }
        p.setFrameOrigin(Placement.fit(r, in: app.froggScreen).origin)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(l)
        NSAnimationContext.runAnimationGroup { ctx in  // 220 ms grow-in (C8 mmIn), on the system's display-synced animator
            ctx.duration = 0.22
            p.animator().alphaValue = 1
        }
        listPanel = p
        list = l
        watchOutside()
        Debug.log("list open rows=\(rows.map(\.id))")
    }

    func closeList() {
        guard let p = listPanel else { return }
        listPanel = nil
        list = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; p.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }

    // MARK: cards

    func showCard(_ content: NSView, name: String, key: Bool = true) {
        closeCard()
        cardGen += 1
        let card = SurfaceView.card(content, look: cardLook)
        let p = KeyPanel(size: card.frame.size)
        p.level = .popUpMenu
        p.contentView = card
        p.onCancel = { [weak self] in self?.closeCard() }
        app.placeBeside(p, avoid: avoidRects())
        p.makeKeyAndOrderFront(nil)
        cardPanel = p
        Debug.log("card open \(name) look=\(cardLook.glass ? "glass" : "paper")/\(cardLook.variant) dim=\(cardLook.dim)")
    }

    func closeCard() {
        cardGen += 1
        cardPanel?.orderOut(nil)
        cardPanel = nil
    }

    func resizeCard(_ content: NSView) {
        guard let p = cardPanel, let card = p.contentView as? SurfaceView else { return }
        let top = p.frame.maxY
        let h = content.frame.height + card.shadowInsetPublic
        card.setFrameSize(NSSize(width: card.frame.width, height: h))
        p.setContentSize(card.frame.size)
        p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: top))
    }

    func showAsk() {
        let card = AskCard(placeholder: ui.askPlaceholder, look: cardLook)
        card.fit()
        card.onClose = { [weak self] in self?.closeCard() }
        card.onOpenURL = { NSWorkspace.shared.open($0) }  // the text-fragment link reopens the passage, highlighted
        card.onAsk = { [weak self, weak card] q in
            guard let self, let card else { return }
            self.app.ask(q) { result in
                switch result {
                case .success(let r): card.show(r)
                case .failure(let e): card.show(error: e)
                }
                self.resizeCard(card)
            }
        }
        showCard(card, name: "ask")
        cardPanel?.makeFirstResponder(card.field)
    }

    func showMemory() {
        let gen = cardGen
        Task { @MainActor in
            let items = await app.client.highlights()
            guard gen == cardGen else { Debug.log("highlights fetched after something else opened: dropped"); return }
            let card = MemoryCard(highlights: items, look: cardLook)
            card.fit()
            card.onClose = { [weak self] in self?.closeCard() }
            card.onOpenURL = { NSWorkspace.shared.open($0) }
            showCard(card, name: "memory (\(items.count))")
        }
    }

    /// Opens at once with what we already know, then refreshes in place if it's still the open card.
    func showWallet() {
        func make(_ info: WalletInfo?, _ pays: [Receipt]) -> WalletCard {
            let card = WalletCard(info: info, payments: pays, look: cardLook)
            card.fit()
            card.onClose = { [weak self] in self?.closeCard() }
            card.onOpenURL = { NSWorkspace.shared.open($0) }
            card.onSetup = { [weak self] in self?.app.openWallet() }
            return card
        }
        showCard(make(wallet, []), name: "wallet")
        let gen = cardGen
        Task { @MainActor in
            let info = await app.client.wallet()
            wallet = info
            let pays = await app.client.payments()
            guard gen == cardGen, let p = cardPanel else { Debug.log("wallet fetched after its card closed: dropped"); return }
            let top = p.frame.maxY
            let card = SurfaceView.card(make(info, pays), look: cardLook)
            p.contentView = card
            p.setContentSize(card.frame.size)
            p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: top))
            p.setFrame(Placement.fit(p.frame, in: app.froggScreen), display: true)
        }
    }

    /// Keeps the wallet sub-label ("0.95 Ⓝ") fresh for the next open.
    func refreshWallet() {
        Task { @MainActor in wallet = await app.client.wallet() }
    }
}

extension SurfaceView {
    var shadowInsetPublic: CGFloat { look.glass ? 0 : 3 }
}
