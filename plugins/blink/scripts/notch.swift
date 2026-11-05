// blink for macOS: the agent bar in the notch. A resident helper, the Mac twin of ui.ps1.
//   notch <state dir> <settings file>
// bell.sh compiles this once with swiftc (Xcode Command Line Tools) into the state dir, drops one key=value file per
// event into <state>/spool and waits for answers in <state>/replies. Without swiftc it falls back to system banners.
// At rest: the two eyes left of the notch, one coloured dot per running agent right of it.
// A request opens the island with Allow / Deny; hovering opens the list of all agents. Never takes the focus.
import Cocoa

let stateDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory() + "/.cache/blink"
let confPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSHomeDirectory() + "/.config/blink/settings.conf"
let spool = stateDir + "/spool", replies = stateDir + "/replies"
let fm = FileManager.default
try? fm.createDirectory(atPath: spool, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: replies, withIntermediateDirectories: true)

// One helper per user: the lock goes away with the process.
let lockFd = open(stateDir + "/notch.lock", O_CREAT | O_RDWR, 0o600)
if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 { exit(0) }

func rgb(_ hex: String) -> NSColor {
    let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
    return NSColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let orange = rgb("#FF7A12")
let palette = ["#B18CFF", "#4CC38A", "#FF6FAE", "#F5D04E", "#3FD0D4", "#FF8A70", "#9FB4C7", "#C8A27A"]
let expoOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)                  // the site's easing
var panelTarget = NSRect.zero
var speed = 1.0, position = "top-center", attached = true                            // from the settings file, read on every render

func readConf() -> [String: String] {
    var c: [String: String] = [:]
    for l in ((try? String(contentsOfFile: confPath, encoding: .utf8)) ?? "").split(separator: "\n") {
        if let i = l.firstIndex(of: "="), !l.hasPrefix("#") { c[String(l[..<i])] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces) }
    }
    return c
}
func colorKey(_ project: String) -> String {
    let ok = project.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
    return "color." + (ok.isEmpty ? "none" : ok)
}

final class Agent {
    let key: String; var agent: String; var project: String; var session = ""; var color: String
    var state = "work"; var since = Date(); var seen = Date()
    var title = ""; var message = ""; var command = ""; var reply = ""; var replyEnd = Date.distantPast; var allow = false
    init(key: String, agent: String, project: String, color: String) { self.key = key; self.agent = agent; self.project = project; self.color = color }
    var name: String { !session.isEmpty ? session : !project.isEmpty ? project : agent }
    var waiting: Bool { state == "ask" && !reply.isEmpty && Date() < replyEnd }
}
var agents: [Agent] = []

// Quick Allow only when the island can show exactly what will run: a shell command or a read-only tool's target, parsed
// with a real JSON parser, short enough to show whole, on one line, with no control or invisible format characters.
let readOnly = ["Read": "file_path", "Glob": "pattern", "Grep": "pattern", "WebFetch": "url", "WebSearch": "query", "LS": "path"]
func detail(_ rawPath: String) -> (text: String, safe: Bool) {
    defer { try? fm.removeItem(atPath: rawPath) }
    guard let d = fm.contents(atPath: rawPath), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return ("", false) }
    let tool = j["tool_name"] as? String ?? "", input = j["tool_input"] as? [String: Any] ?? [:]
    var text = "", ok = false
    if tool == "Bash", let c = input["command"] as? String { text = c; ok = true }
    else if let k = readOnly[tool], let v = input[k] as? String { text = "\(tool): \(v)"; ok = true }
    else if !tool.isEmpty { text = tool }
    let bad = text.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) || ($0.properties.isWhitespace && $0 != " ") }
    return (text, ok && text.count <= 600 && !bad)
}

// ---- views --------------------------------------------------------------------------------------------------------
func label(_ s: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: s); t.textColor = color; t.lineBreakMode = .byTruncatingTail
    t.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    return t
}
final class Button: NSView {
    let action: () -> Void
    init(_ text: String, fill: NSColor, ink: NSColor, frame: NSRect, action: @escaping () -> Void) {
        self.action = action; super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = fill.cgColor; layer?.cornerRadius = 8
        let t = label(text, 12.5, ink, .semibold); t.alignment = .center
        t.frame = NSRect(x: 0, y: (frame.height - 17) / 2, width: frame.width, height: 17); addSubview(t)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    func scale(_ to: CGFloat, _ time: Double) {                                       // sinks under the finger, springs back
        guard let l = layer else { return }
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5); l.position = CGPoint(x: frame.midX, y: frame.midY)
        let a = CASpringAnimation(keyPath: "transform.scale"); a.fromValue = l.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        a.toValue = to; a.damping = 14; a.stiffness = 420; a.duration = time
        l.add(a, forKey: "press"); l.setValue(to, forKeyPath: "transform.scale")
    }
    override func mouseDown(with e: NSEvent) { scale(0.93, 0.12) }
    override func mouseUp(with e: NSEvent) { scale(1, 0.4); if bounds.contains(convert(e.locationInWindow, from: nil)) { action() } }
}
final class Dot: NSView {
    init(_ color: NSColor, size: CGFloat, at: NSPoint, breathe: Bool, dim: Bool, pop: Bool) {
        super.init(frame: NSRect(origin: at, size: NSSize(width: size, height: size))); wantsLayer = true
        layer?.backgroundColor = color.cgColor; layer?.cornerRadius = size / 2; layer?.opacity = dim ? 0.35 : 1
        if breathe {                                                                  // whoever needs you breathes, like the eyes
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0.35; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            layer?.add(a, forKey: "breathe")
        }
        if pop {                                                                      // a new agent pops in
            layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer?.position = CGPoint(x: frame.midX, y: frame.midY)
            let a = CASpringAnimation(keyPath: "transform.scale"); a.fromValue = 0; a.toValue = 1; a.damping = 11; a.stiffness = 260; a.duration = 0.6
            layer?.add(a, forKey: "pop")
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
func rise(_ v: NSView, delay: Double) {                                               // fades in while rising into place
    if speed == 0 { return }
    v.wantsLayer = true; guard let l = v.layer else { return }
    let t = CACurrentMediaTime() + delay / speed
    let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0; o.toValue = 1; o.duration = 0.14 / speed; o.beginTime = t; o.fillMode = .backwards
    let y = CABasicAnimation(keyPath: "transform.translation.y"); y.fromValue = -8; y.toValue = 0; y.duration = 0.24 / speed; y.beginTime = t; y.timingFunction = expoOut; y.fillMode = .backwards
    l.add(o, forKey: "fade"); l.add(y, forKey: "rise")
}

final class Island: NSView {
    var onHover: (Bool) -> Void = { _ in }
    override func draw(_ r: NSRect) {
        NSColor.black.setFill()
        let r = min(20, bounds.height * 0.4)
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        if attached { NSRect(x: 0, y: r, width: bounds.width, height: bounds.height - r).fill() }   // square top: it merges into the notch
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover(true) }
    override func mouseExited(with e: NSEvent) { onHover(false) }
}

// ---- the island ---------------------------------------------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)                                                  // no Dock icon, no focus change
func notchScreen() -> NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0] }
let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)         // over the menu bar, where the notch is
panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.becomesKeyOnlyIfNeeded = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
let island = Island(frame: panel.contentLayoutRect); island.wantsLayer = true; island.autoresizingMask = [.width, .height]
panel.contentView = island

var hovering = false, isOpen = false, lastActivity = Date(), popKeys = Set<String>()

func barHeight(_ s: NSScreen) -> CGFloat { max(s.safeAreaInsets.top, 28) }
func notchWidth(_ s: NSScreen) -> CGFloat {
    guard s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
    return s.frame.width - l.width - r.width
}
func place(_ w: CGFloat, _ h: CGFloat, animated: Bool) {
    let s = notchScreen(), v = s.visibleFrame, m: CGFloat = 10
    let x = position.hasSuffix("left") ? v.minX + m : position.hasSuffix("right") ? v.maxX - m - w : s.frame.midX - w / 2
    let y = position == "top-center" ? s.frame.maxY - h : position.hasPrefix("top") ? v.maxY - m - h : v.minY + m
    let f = NSRect(x: x, y: y, width: w, height: h); panelTarget = f
    if !animated || speed == 0 { panel.setFrame(f, display: true); return }
    NSAnimationContext.runAnimationGroup { c in c.duration = 0.2 / speed; c.timingFunction = expoOut; panel.animator().setFrame(f, display: true) }
}
func answer(_ a: Agent, _ value: String) {
    guard !a.reply.isEmpty else { return }
    try? value.write(toFile: replies + "/" + a.reply, atomically: true, encoding: .utf8)   // bell.sh is waiting for this file
    a.reply = ""; a.allow = false; a.state = value == "terminal" ? "ask" : "work"; a.since = Date(); render()
}
func ago(_ d: Date) -> String { let m = Int(Date().timeIntervalSince(d) / 60); return m < 1 ? "now" : m < 60 ? "\(m) min" : "\(m / 60) h" }

func render() {
    island.subviews.forEach { $0.removeFromSuperview() }
    let conf = readConf()
    menuBar(conf)
    speed = conf["anim"] == "0" ? 0 : (Double(conf["anim_speed"] ?? "") ?? 100) / 100
    position = conf["dock_pos"] ?? "top-center"; if position == "free" { position = "top-center" }   // dragging is Windows only for now
    attached = position == "top-center"
    panel.alphaValue = CGFloat(Double(conf["dock_alpha"] ?? "") ?? 100) / 100
    let askColor = rgb(conf["eye_ask"] ?? "#FF7A12"), workColor = rgb(conf["eye_work"] ?? "#4DA3FF")
    let visible = conf["dock"] != "0" && (conf["dock_when"] != "ask" || agents.contains { $0.state == "ask" })
    if agents.isEmpty || !visible { panel.orderOut(nil); isOpen = false; return }
    let s = notchScreen(), bar = barHeight(s), notch = attached ? notchWidth(s) : 0
    let asking = agents.first { $0.waiting }
    if conf["dock_open"] == "never" { hovering = false }
    let wasOpen = isOpen; isOpen = hovering || asking != nil
    let ear: CGFloat = 16, dotsW = CGFloat(agents.count) * 15
    let side = max(52, dotsW) + ear                                                   // both ears the same: the notch stays centred
    let closedW = notch > 0 ? notch + side * 2 : 62 + dotsW + 16
    let w = isOpen ? max(closedW, 460) : closedW
    var rows: [Agent] = []; if isOpen { rows = hovering ? agents : (asking.map { [$0] } ?? []) }
    let cardH: CGFloat = (!hovering && asking != nil) ? (asking!.command.isEmpty ? 94 : 126) : 0
    let listH = hovering ? CGFloat(agents.count) * 54 + 16 : 0
    let h = bar + (isOpen ? cardH + listH : 0)
    place(w, h, animated: panel.isVisible)
    if !panel.isVisible { panel.orderFrontRegardless() }
    island.frame = NSRect(x: 0, y: 0, width: w, height: h); island.needsDisplay = true

    // the bar: eyes on the left ear, one dot per agent on the right
    let eye = agents.contains { $0.state == "ask" } ? askColor : workColor
    let y = h - bar / 2
    for x in [ear, ear + 16] {
        let e = NSView(frame: NSRect(x: x, y: y - 3, width: 12, height: 6)); e.wantsLayer = true
        e.layer?.backgroundColor = eye.cgColor; e.layer?.cornerRadius = 2
        e.layer?.shadowColor = eye.cgColor; e.layer?.shadowOpacity = 1; e.layer?.shadowRadius = 6; e.layer?.shadowOffset = .zero
        island.addSubview(e)
    }
    var x = w - ear - dotsW + 6
    for a in agents {
        island.addSubview(Dot(rgb(a.color), size: 9, at: NSPoint(x: x, y: y - 4.5), breathe: a.state == "ask", dim: a.state == "done", pop: popKeys.contains(a.key)))
        x += 15
    }
    popKeys.removeAll()

    // a request: who, what, and the answers
    if !hovering, let a = asking {
        let top = h - bar - 8
        let head = label((a.agent == "codex" ? "CODEX" : "CLAUDE CODE") + (a.project.isEmpty ? "" : "  ·  " + a.project.uppercased()), 10, NSColor(white: 0.55, alpha: 1), mono: true)
        head.frame = NSRect(x: 36, y: top - 14, width: w - 52, height: 14)
        let d = Dot(rgb(a.color), size: 9, at: NSPoint(x: 16, y: top - 11), breathe: false, dim: false, pop: false)
        let name = label(a.name, 14, .white, .semibold); name.frame = NSRect(x: 16, y: top - 36, width: w - 32, height: 19)
        var parts: [NSView] = [d, head, name]
        var bottom = top - 40
        if !a.command.isEmpty {
            let box = NSView(frame: NSRect(x: 16, y: bottom - 28, width: w - 32, height: 26)); box.wantsLayer = true
            box.layer?.backgroundColor = rgb("#0C0C0E").cgColor; box.layer?.cornerRadius = 7; box.layer?.borderColor = rgb("#25252A").cgColor; box.layer?.borderWidth = 1
            let c = label("$ " + a.command, 11.5, rgb("#E6E4DF"), mono: true); c.frame = NSRect(x: 9, y: 5, width: w - 50, height: 16); box.addSubview(c)
            parts.append(box); bottom -= 32
        }
        var bx: CGFloat = 16   // Allow needs the whole command on screen: a cut-off line could hide what runs
        let shown = ("$ " + a.command as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)]).width <= w - 54
        if a.allow && shown { parts.append(Button("Allow", fill: orange, ink: rgb("#111113"), frame: NSRect(x: bx, y: bottom - 30, width: 76, height: 28)) { answer(a, "allow") }); bx += 84 }
        parts.append(Button("Deny", fill: rgb("#1E1E22"), ink: .white, frame: NSRect(x: bx, y: bottom - 30, width: 76, height: 28)) { answer(a, "deny") }); bx += 84
        parts.append(Button("In terminal", fill: .clear, ink: NSColor(white: 0.55, alpha: 1), frame: NSRect(x: bx, y: bottom - 30, width: 92, height: 28)) { answer(a, "terminal") })
        for (i, p) in parts.enumerated() { island.addSubview(p); if !wasOpen { rise(p, delay: 0.03 + Double(i) * 0.02) } }
    }

    // hover: every agent, what it is doing, the same answers
    if hovering {
        var ry = h - bar - 54
        for (i, a) in rows.enumerated() {
            let row = NSView(frame: NSRect(x: 16, y: ry, width: w - 32, height: 48)); row.wantsLayer = true
            row.layer?.backgroundColor = (a.state == "ask" ? orange.withAlphaComponent(0.15) : NSColor(white: 1, alpha: 0.05)).cgColor; row.layer?.cornerRadius = 11
            row.addSubview(Dot(rgb(a.color), size: 11, at: NSPoint(x: 12, y: 18), breathe: false, dim: false, pop: false))
            let what = a.state == "ask" ? "needs you" : a.state == "work" ? "working" : "finished"
            let t1 = label(a.name, 13, .white, .semibold); t1.frame = NSRect(x: 33, y: 25, width: w - 210, height: 17)
            let who = a.agent == "codex" ? "Codex" : "Claude Code"
            let t2 = label("\(who) · \(a.project.isEmpty ? "" : a.project + " · ")\(what) · \(ago(a.since))", 11, a.state == "ask" ? rgb("#FF9A4D") : NSColor(white: 0.52, alpha: 1))
            t2.frame = NSRect(x: 33, y: 8, width: w - 210, height: 15)
            row.addSubview(t1); row.addSubview(t2)
            if a.waiting {
                // no Allow here: the row does not show the command. Move away and the request shows it whole.
                row.addSubview(Button("Deny", fill: rgb("#1E1E22"), ink: .white, frame: NSRect(x: w - 32 - 11 - 58, y: 11, width: 58, height: 26)) { answer(a, "deny") })
            }
            island.addSubview(row); if !wasOpen { rise(row, delay: 0.02 + Double(i) * 0.02) }
            ry -= 54
        }
    }
}
island.onHover = { inside in
    if inside { if !hovering { hovering = true; render() } }
    // leaving is judged in poll(): the island is still growing while the mouse runs for its far end
}

// ---- the icon in the menu bar ---------------------------------------------------------------------------------------
final class Menu: NSObject {
    @objc func settings() { NSWorkspace.shared.open(URL(fileURLWithPath: confPath)) }
    @objc func quit() { exit(0) }
}
let menuActions = Menu()
var statusItem: NSStatusItem?
func eyesIcon() -> NSImage {
    let i = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 8, height: 4), xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(roundedRect: NSRect(x: 12, y: 6, width: 8, height: 4), xRadius: 1.5, yRadius: 1.5).fill()
        return true
    }
    i.isTemplate = true; return i                                                    // follows the light or dark menu bar
}
func menuBar(_ conf: [String: String]) {
    if conf["tray"] == "0" { if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }; return }
    if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); statusItem?.button?.image = eyesIcon() }
    let m = NSMenu()
    for a in agents { m.addItem(withTitle: "\(a.name): \(a.state == "ask" ? "needs you" : a.state == "work" ? "working" : "finished")", action: nil, keyEquivalent: "") }
    if !agents.isEmpty { m.addItem(.separator()) }
    for (t, s) in [("Settings file", #selector(Menu.settings)), ("Quit Blink", #selector(Menu.quit))] {
        let i = m.addItem(withTitle: t, action: s, keyEquivalent: ""); i.target = menuActions
    }
    statusItem?.menu = m
}

// ---- events -------------------------------------------------------------------------------------------------------
func pickColor(_ project: String, _ c: [String: String]) -> String {
    if let pin = c[colorKey(project)], !pin.isEmpty { return pin }
    let used = Set(agents.map { $0.color })
    return palette.first { !used.contains($0) } ?? palette[agents.count % palette.count]
}
func handle(_ e: [String: String]) {
    let key = e["key"] ?? "", kind = e["kind"] ?? ""
    if key.isEmpty || kind.isEmpty { return }
    lastActivity = Date()
    if kind == "end" { agents.removeAll { $0.key == key }; return }
    var a = agents.first { $0.key == key }
    if a == nil {
        a = Agent(key: key, agent: e["agent"] ?? "claude", project: e["project"] ?? "", color: pickColor(e["project"] ?? "", readConf()))
        agents.append(a!); popKeys.insert(key)
    }
    guard let a else { return }
    if let v = e["session"], !v.isEmpty { a.session = v }
    if let v = e["project"], !v.isEmpty { a.project = v }
    let state = kind == "ask" ? "ask" : kind == "work" ? "work" : "done"
    if state != a.state { a.state = state; a.since = Date() }
    a.seen = Date(); a.reply = e["reply"] ?? ""; a.allow = false
    a.replyEnd = a.reply.isEmpty ? .distantPast : Date().addingTimeInterval(Double(e["wait"] ?? "0") ?? 0)
    a.title = e["title"] ?? ""; a.message = e["msg"] ?? ""; a.command = ""
    if kind == "ask" {
        let d = e["raw"].map(detail) ?? ("", false)
        a.command = readConf()["show_cmd"] == "0" ? "" : (d.0.isEmpty ? e["cmd"] ?? "" : d.0)
        a.allow = d.1 && !a.command.isEmpty && !a.reply.isEmpty
    }
}
func poll() {
    let files = ((try? fm.contentsOfDirectory(atPath: spool)) ?? []).filter { $0.hasSuffix(".evt") }.sorted()
    var changed = false
    for f in files {
        let p = spool + "/" + f; var e: [String: String] = [:]
        for l in ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").split(separator: "\n") {
            if let i = l.firstIndex(of: "=") { e[String(l[..<i])] = String(l[l.index(after: i)...]) }
        }
        try? fm.removeItem(atPath: p); handle(e); changed = true
    }
    if hovering, !panelTarget.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) { hovering = false; changed = true }
    if isOpen, !hovering, !agents.contains(where: { $0.waiting }) { changed = true }    // the wait ran out: fold back
    if changed { render() }
}
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in poll() }
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    fm.createFile(atPath: stateDir + "/heartbeat", contents: Data())
    let now = Date(), before = agents.count                                          // quiet sessions drop off the bar
    agents.removeAll { let idle = now.timeIntervalSince($0.seen); return ($0.state == "done" && idle > 1800) || idle > 21600 }
    if agents.count != before { render() }
    if agents.isEmpty && statusItem == nil && now.timeIntervalSince(lastActivity) > 14400 { exit(0) }
}
fm.createFile(atPath: stateDir + "/heartbeat", contents: Data())
menuBar(readConf())
app.run()
