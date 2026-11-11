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

    /// The last app the user switched to that isn't the Pixl: the "page in front" for "save this",
    /// even when the Ask card stayed open while they moved to another window.
    var lastOtherApp: NSRunningApplication?

    init(app: AppController) {
        self.app = app
        let ws = NSWorkspace.shared
        lastOtherApp = ws.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let a, a != .current { self?.lastOtherApp = a } }
        }
    }

    var isOpen: Bool { view.map { $0.phase != .closed } ?? false }
    var isAnimating: Bool { view?.isAnimating ?? false }
    var ui: PixlUI { app.ui }

    // MARK: looks (legibility: text surfaces dim enough for 4.5:1 over anything)

    var prefersDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    /// C10: Liquid Glass is the ghost's alone (its body is glass); every other Pixl uses Solid.
    var glass: Bool { SurfaceView.Look.glassAvailable && ui.glassBody }
    var iconLook: SurfaceView.Look { .icon(prefersDark: prefersDark, glass: glass) }
    var labelLook: SurfaceView.Look { .text(designFill: prefersDark ? 0.66 : 0.62, prefersDark: prefersDark, glass: glass) }
    var cardLook: SurfaceView.Look { .text(designFill: prefersDark ? 0.42 : 0.26, prefersDark: prefersDark, glass: glass) }
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
        let slots = BubbleMenuModel.slots(selection: app.pendingSelection != nil, peer: app.travel.sendSlotName, walletSub: wallet?.short,
                                          agentsSub: app.agents.bubbleSub)
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
        v.style = ui.menuStyle  // Silky's bubbles hang on threads, Boo's trail wisps
        if ui.menuStyle == "wisp" { v.styleColor = accent }
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
        case "agents": showAgents(near: "agents")
        case "more": showMore()
        case "play": showPlay(near: "play")
        case "send": close(reason: "send"); showSend()
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
                    ListMenuView.Row(id: "agents", title: "Agents", icon: "agents", trailing: app.agents.bubbleSub ?? "connect Claude Code"),
                    ListMenuView.Row(id: "memory", title: "Memory", icon: "memory"),
                    ListMenuView.Row(id: "wallet", title: "Wallet", icon: "wallet", trailing: wallet?.short),
                    ListMenuView.Row(id: "send", title: "Send to device", icon: "send",
                                     trailing: app.travel.localNetworkBlocked ? "allow Local Network" : app.travel.peers.isEmpty ? "none nearby" : nil,
                                     enabled: app.travel.localNetworkBlocked || !app.travel.peers.isEmpty),
                    ListMenuView.Row(id: "focus", title: app.focusUntil == nil ? "Focus for 25 min" : "Stop focus", icon: nil),
                    ListMenuView.Row(id: "signature", title: "Do a trick", icon: nil, trailing: ui.signature),
                    ListMenuView.Row(id: "play", title: "Play", icon: "play", trailing: app.game.ownGame.map(GameController.title)),
                    ListMenuView.Row(id: "skin", title: "Change Pixl", icon: nil, trailing: app.settings.name),
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
        case "agents": showAgents(near: nil)
        case "focus": app.focusUntil == nil ? app.startFocus(minutes: 25) : app.endFocus(completed: false)
        case "signature": app.signature()
        case "skin": showSkins()
        case "send": showSend()
        case "play": showPlay(near: nil)
        case "settings": app.toggleMiniMenu()
        case "hide": app.toggleHidden()
        default: break
        }
    }

    /// Play: this Pixl's own game first, then the others, dimmed with a hint to switch Pixl.
    func showPlay(near slot: String?) {
        let own = app.game.ownGame
        let all: [GameController.Kind] = [.inevitable, .snap, .laser]
        let ordered = own.map { o in [o] + all.filter { $0 != o } } ?? all
        let rows = ordered.map { k in
            ListMenuView.Row(id: "play.\(k.rawValue)", title: GameController.title(k), icon: k == own ? "play" : nil,
                             trailing: k == own ? GameController.blurb(k) : "\(GameController.owner(k)) only · switch Pixl", enabled: k == own)
        }
        if slot != nil { view?.close(at: app.now) }
        showList(rows, near: slot) { [weak self] row in
            guard let self, let k = GameController.Kind(rawValue: String(row.id.dropFirst("play.".count))) else { return }
            self.closeList()
            self.close(reason: "play")
            self.app.game.start(k)
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

    // MARK: Agent mode (SPEC §16)

    /// Sessions (waiting ones first), then the switches. Redraws while open as hooks report in.
    func showAgents(near slot: String?) {
        let agents = app.agents
        guard agents.hooksInstalled || !agents.hub.sessions.isEmpty else { showConnectAgents(near: slot); return }
        func age(_ d: Date) -> String {
            let s = Int(Date().timeIntervalSince(d))
            return s < 60 ? "now" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h"
        }
        var rows: [ListMenuView.Row] = agents.hub.requests.map { r in
            ListMenuView.Row(id: "req.\(r.id)", title: "\(r.project): \(r.summary)", icon: "warn", trailing: "needs you")
        }
        let waiting = Set(agents.hub.requests.map(\.sessionID))
        rows += agents.hub.list.filter { !waiting.contains($0.id) }.map { s in
            ListMenuView.Row(id: "ses.\(s.id)", title: "\(s.project) · \(s.doing)", icon: nil, trailing: age(s.lastHeard), enabled: false)
        }
        if agents.hub.sessions.isEmpty {
            rows.append(ListMenuView.Row(id: "none", title: "No Claude Code sessions right now", icon: "info", enabled: false))
        }
        rows += agents.extraRows?() ?? []
        rows += [ListMenuView.Row(id: "answer", title: "Answer from Pixlz", icon: nil, trailing: agents.answerHere ? "on" : "off"),
                 ListMenuView.Row(id: "alerts", title: "Agent alerts", icon: nil, trailing: agents.alertsOn ? "on" : "off"),
                 ListMenuView.Row(id: "cloud", title: "Cloud sessions: open claude.ai/code", icon: nil),
                 ListMenuView.Row(id: "disconnect", title: "Disconnect Claude Code", icon: nil)]
        if slot != nil { view?.close(at: app.now) }
        showList(rows, near: slot) { [weak self] row in
            guard let self else { return }
            switch row.id {
            case let id where id.hasPrefix("req."): self.showRequest(String(id.dropFirst(4)))
            case "answer": agents.answerHere.toggle(); self.showAgents(near: nil)
            case "alerts": agents.alertsOn.toggle(); self.showAgents(near: nil)
            case "cloud": self.closeList(); NSWorkspace.shared.open(URL(string: "https://claude.ai/code")!)
            case "disconnect":
                self.closeList()
                if let why = agents.removeHooks() { self.app.notify(.agentsError(why)) }
                else { self.app.notify(.agents("Claude Code disconnected. Its settings are back as they were.")) }
            default: agents.onExtraRow?(row.id)
            }
        }
        agents.onChange = { [weak self] in
            guard let self, self.listPanel != nil, self.list?.rows.contains(where: { $0.id == "answer" }) == true else { return }
            self.showAgents(near: nil)
        }
    }

    /// The user's yes before Pixlz writes to Claude Code's settings (D19).
    func showConnectAgents(near slot: String?) {
        let rows = [ListMenuView.Row(id: "info", title: "Agent mode watches your Claude Code sessions.", icon: "info", enabled: false),
                    ListMenuView.Row(id: "info2", title: "It adds Pixlz hooks to ~/.claude/settings.json.", icon: nil, enabled: false),
                    ListMenuView.Row(id: "connect", title: "Connect Claude Code", icon: "agents", trailing: "↵"),
                    ListMenuView.Row(id: "cancel", title: "Not now", icon: nil, trailing: "esc")]
        if slot != nil { view?.close(at: app.now) }
        showList(rows, near: slot) { [weak self] row in
            guard let self else { return }
            self.closeList()
            guard row.id == "connect" else { return }
            if let why = self.app.agents.installHooks() {
                self.app.notify(.agentsError(why))
            } else {
                self.app.notify(.agents("Connected. Sessions you start (or resume) from now on show up under Agents."))
            }
        }
    }

    /// One request: the exact command or file, Allow / Deny, snooze.
    func showRequest(_ id: String) {
        let agents = app.agents
        guard let r = agents.hub.requests.first(where: { $0.id == id }) else { showAgents(near: nil); return }
        let detail = r.detail.count > 160 ? String(r.detail.prefix(159)) + "…" : r.detail
        var rows = [ListMenuView.Row(id: "what", title: "\(r.project) wants to: \(r.summary)", icon: "warn", enabled: false)]
        if !detail.isEmpty, detail != r.summary {
            rows += detail.split(separator: "\n", omittingEmptySubsequences: true).prefix(4).enumerated().map { i, l in
                ListMenuView.Row(id: "detail.\(i)", title: String(l), icon: nil, enabled: false)
            }
        }
        if agents.canAnswer(id) {
            rows += [ListMenuView.Row(id: "allow", title: "Allow", icon: "check", trailing: "↵"),
                     ListMenuView.Row(id: "deny", title: "Deny", icon: nil)]
        } else {
            rows.append(ListMenuView.Row(id: "terminal", title: "Answer it in the terminal (turn on Answer from Pixlz to answer here)",
                                         icon: "info", enabled: false))
        }
        rows.append(ListMenuView.Row(id: "snooze", title: "Snooze alerts 10 min", icon: nil))
        showList(rows, near: nil) { [weak self] row in
            guard let self else { return }
            switch row.id {
            case "allow": self.closeList(); agents.decide(id, .allow)
            case "deny": self.closeList(); agents.decide(id, .deny)
            case "snooze": agents.snooze(); self.closeList()
            default: break
            }
        }
        agents.onChange = { [weak self] in
            // answered in the terminal, or timed out: the card goes
            guard let self, !agents.hub.requests.contains(where: { $0.id == id }),
                  self.list?.rows.contains(where: { $0.id == "snooze" }) == true else { return }
            self.closeList()
        }
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

    weak var skinCard: SkinCard?
    /// Closes a card that closes on a click outside it (Change Pixl).
    var cardOutsideMonitor: Any?

    func closeCard() {
        if let m = cardOutsideMonitor { NSEvent.removeMonitor(m); cardOutsideMonitor = nil }
        app.shellOut("vault")
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
        // grow downward, but never off the screen: a long answer moves the card up instead
        var y = top
        if let vis = (p.screen ?? NSScreen.main)?.visibleFrame {
            y = min(max(top, vis.minY + p.frame.height), vis.maxY)
        }
        p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: y))
    }

    /// The open Ask card (debug commands type into it).
    weak var askCard: AskCard?

    func showAsk() {
        let card = AskCard(placeholder: ui.askPlaceholder, look: cardLook)
        askCard = card
        card.fit()
        card.onClose = { [weak self] in self?.closeCard() }
        card.onOpenURL = { NSWorkspace.shared.open($0) }  // the text-fragment link reopens the passage, highlighted
        card.onHandOff = { [weak self] text in self?.showHandOff(text) }
        card.onSaveAnswer = { [weak self] question, answer, sources in
            // the answer goes into memory with the links it was built from, so it can be found again
            let links = sources.compactMap { $0.fragmentUrl ?? $0.url }
            let text = answer + (links.isEmpty ? "" : "\n\nSources:\n" + links.map { "• " + $0 }.joined(separator: "\n"))
            Task { @MainActor in
                do {
                    _ = try await self?.app.client.saveNote(text, title: question, folder: "Answers")
                    self?.app.notify(.answerSaved, voice: .happy)
                } catch { self?.app.notify(.answerNotSaved) }
            }
        }
        card.onAsk = { [weak self, weak card] q in
            guard let self, let card else { return }
            // "open Spotify", "go to github.com", "save this": done on the Mac, no model
            let front = self.lastOtherApp ?? self.previousApp
            self.app.intents.progress = { [weak self, weak card] text in
                guard let self, let card else { return }
                card.showProgress(text)
                self.resizeCard(card)
            }
            let handled = self.app.intents.run(q, front: front) { [weak self, weak card] r in
                guard let self, let card else { return }
                let saved = !r.items.isEmpty && !r.found
                card.showLocal(r.said, saved: r.items, caption: r.found ? "FROM YOUR NOTES" : "SAVED TO MEMORY",
                               note: saved ? "saved on this Mac · no model" : r.found ? "found on this Mac · nothing sent" : "done on this Mac · nothing sent")
                self.app.show(saved ? "emotion_proud" : "emotion_happy", for: 2)
                self.resizeCard(card)
            }
            if handled { return }
            // screens, devices, "jump to …": answered on the Mac, nothing sent anywhere
            if let local = self.app.travel.localAnswer(q) {
                Debug.log("ask: answered locally")
                card.showLocal(local)
                self.resizeCard(card)
                return
            }
            self.app.ask(q) { result in
                switch result {
                case .success(let r):
                    card.show(r)
                    self.app.travel.noteAnswer(question: q, answer: r.answer)
                    // an answer that lists places or things: their pictures, looked up by name on Wikipedia
                    Task { @MainActor [weak self, weak card] in
                        let pics = await AnswerPictures.find(for: r.answer)
                        Debug.log("ask: \(pics.count) pictures")
                        guard let self, let card, card.lastAnswer == r.answer else { return }
                        card.showPictures(pics) { [weak self, weak card] in if let card { self?.resizeCard(card) } }
                    }
                case .failure(let e): card.show(error: e)
                }
                self.resizeCard(card)
            }
        }
        showCard(card, name: "ask")
        cardPanel?.makeFirstResponder(card.field)
    }

    /// Send to a nearby device: straight there if there's one, else pick it.
    func showSend() {
        if app.travel.localNetworkBlocked { app.travel.openLocalNetworkSettings(); return }
        let peers = app.travel.peers
        if peers.count == 1 { app.travel.send(to: peers[0]); return }
        guard !peers.isEmpty else { app.notify(.noDevices); return }
        showList(peers.map { ListMenuView.Row(id: $0.deviceId, title: $0.deviceName, icon: "send") }, near: nil) { [weak self] row in
            guard let self, let p = peers.first(where: { $0.deviceId == row.id }) else { return }
            self.closeList()
            self.app.travel.send(to: p)
        }
    }

    func showSkins() {
        let card = SkinCard(selected: PixlSkins.currentID, look: cardLook)
        skinCard = card
        card.fit()
        card.onClose = { [weak self] in self?.closeCard() }
        card.picker.onCancel = { [weak self] in self?.closeCard() }
        // the card stays open while you try Pixls on; a click outside it (or Esc, or ×) closes it
        card.picker.onPick = { [weak self] id in
            self?.app.setSkin(id)
            self?.cardPanel?.orderFrontRegardless()
        }
        showCard(card, name: "skins")
        cardPanel?.makeFirstResponder(card.picker)
        cardOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCard() }
        }
    }

    /// Hand-off: pick an open app; the Pixl takes the text there (SPEC §6.7, docs/PRODUCT-NOTES.md).
    func showHandOff(_ text: String) {
        let me = NSRunningApplication.current.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .prefix(12)
        let rows = apps.map { ListMenuView.Row(id: "\($0.processIdentifier)", title: $0.localizedName ?? "?", icon: nil, trailing: nil) }
        guard !rows.isEmpty else { app.notify(.noOtherApp); return }
        showList(rows, near: nil) { [weak self] row in
            guard let self, let pid = pid_t(row.id), let target = NSRunningApplication(processIdentifier: pid) else { return }
            self.closeList()
            self.closeCard()
            self.app.handOff(text, to: target)
        }
    }

    func showMemory() {
        let gen = cardGen
        Task { @MainActor in
            let items = await app.client.highlights(limit: 200)
            guard gen == cardGen else { Debug.log("highlights fetched after something else opened: dropped"); return }
            let card = MemoryCard(highlights: items, look: cardLook)
            card.fit()
            card.onClose = { [weak self] in self?.closeCard() }
            card.onOpenURL = { NSWorkspace.shared.open($0) }
            card.addSettingsButton { [weak self] in self?.closeCard(); self?.app.toggleMiniMenu(open: .privacy) }
            card.onSaveNote = { [weak self] text, folder in
                Task { @MainActor in
                    do {
                        _ = try await self?.app.client.saveNote(text, title: nil, folder: folder)
                        self?.app.notify(.noteSaved(folder ?? "Notes"), voice: .happy)
                        self?.showMemory()
                    } catch { self?.app.notify(.noteNotSaved) }
                }
            }
            showCard(card, name: "memory (\(items.count))")
            app.shellIn("vault")   // Slugg: the shell swings open like a little vault
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
            card.onSetLimit = { [weak self] v in self?.updateLimits(perWeek: v) }
            card.onPause = { [weak self] p in self?.updateLimits(paused: p) }
            card.addSettingsButton { [weak self] in self?.closeCard(); self?.app.toggleMiniMenu(open: .wallet) }
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

    /// The user changed the weekly limit or paused: the service enforces it; the card redraws.
    func updateLimits(perWeek: String? = nil, paused: Bool? = nil) {
        Task { @MainActor in
            do {
                let w = try await app.client.setLimits(perWeekNear: perWeek, paused: paused)
                wallet = w
                Debug.log("wallet limits: week \(w.caps?.perWeekNear ?? "?") paused \(w.paused == true)")
                let week = w.caps?.perWeekNear ?? "?"
                app.notify(paused.map { .walletPaused($0, perWeek: week) } ?? .walletLimit("Weekly limit set to \(week) NEAR."))
                showWallet()
            } catch {
                app.notify(.walletError((error as? MemoryError)?.bubble ?? "Couldn't change the limit."))
            }
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
