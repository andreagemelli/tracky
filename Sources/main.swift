import Cocoa
import Combine
import ServiceManagement
import SwiftUI

// Chrome starts the native messaging host with the extension's origin as an argument.
if CommandLine.arguments.contains(where: { $0.hasPrefix("chrome-extension://") }) { runNativeHost() }

let catalog = Catalog(url: Bundle.main.url(forResource: "models", withExtension: "json")
    ?? URL(fileURLWithPath: "Resources/models.json"))

// MARK: - Store

final class Store: ObservableObject {
    @Published var usages: [Usage] = []
    @Published var hours: Double = UserDefaults.standard.object(forKey: "hours") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(hours, forKey: "hours") }
    }
    private let reader = ClaudeCodeReader(), browser = BrowserReader()
    private var kept: [Usage] = []   // owned by `queue` (or the caller in --dump/--preview)
    private let queue = DispatchQueue(label: "tracky.read", qos: .utility)

    func start() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Reads new log lines; keeps a day so any period can be shown.
    func load() -> [Usage] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        kept = kept.filter { $0.date > cutoff } + reader.read(since: cutoff, catalog: catalog) + browser.read(since: cutoff, catalog: catalog)
        return kept
    }

    private func refresh() {
        queue.async { [self] in
            let all = load()
            DispatchQueue.main.async { self.usages = all }
        }
    }

    var recent: [Usage] { usages.filter { $0.date > Date().addingTimeInterval(-hours * 3600) } }
    var total: Liters { recent.reduce(Liters()) { $0 + $1.water } }
    var active: Bool { usages.contains { $0.date > Date().addingTimeInterval(-90) } }

    /// Water per model and source (Google's surfaces by name), heaviest first.
    var bySource: [(label: String, water: Liters)] {
        Dictionary(grouping: recent) { $0.model.provider == "google" ? $0.model.name : "\(pretty($0.model.name)) · \($0.source)" }
            .map { ($0.key, $0.value.reduce(Liters()) { $0 + $1.water }) }
            .sorted { $0.water.mid > $1.water.mid }
    }

    /// Per model, heaviest first.
    var byModel: [(model: Model, water: Liters)] {
        Dictionary(grouping: recent) { $0.model.name }.values
            .map { ($0[0].model, $0.reduce(Liters()) { $0 + $1.water }) }
            .sorted { $0.water.mid > $1.water.mid }
    }
}

// MARK: - Wording

func fmt(_ l: Double) -> String {
    l >= 1 ? String(format: "%.2f L", l) : l * 1000 >= 10 ? String(format: "%.0f mL", l * 1000) : String(format: "%.1f mL", l * 1000)
}
func pretty(_ name: String) -> String {
    if name.first?.isUppercase == true { return name }   // already a display name, e.g. "Google AI Overview"
    return name.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1.$2", options: .regularExpression)
        .replacingOccurrences(of: "-", with: " ").capitalized
        .replacingOccurrences(of: "Gpt", with: "GPT")
}

/// Everyday amounts of water, smallest first. Passing one makes Tracky a level hotter.
let containers: [(name: String, liters: Double, sprite: [String])] = [
    ("cup", 0.25, Sprites.cup),
    ("bottle", 1.5, Sprites.bottle),
    ("toilet flush", 6, Sprites.toilet),   // US federal limit, 1.6 gal per flush (EPA WaterSense)
    ("bucket", 10, Sprites.bucket),
    ("shower", 60, Sprites.shower),        // average US shower, 15.8 gal (home-water-works.org)
    ("bathtub", 150, Sprites.tub),
]
/// The first container not yet full, how full it is, and its index (Tracky's heat level).
func container(for l: Double) -> (name: String, sprite: [String], fill: Double, level: Int) {
    let i = containers.firstIndex { l < $0.liters } ?? containers.count - 1
    return (containers[i].name, containers[i].sprite, min(l / containers[i].liters, 1), i)
}

let sliceColors = [Color(red: 0.33, green: 0.62, blue: 0.96), Color(red: 0.2, green: 0.74, blue: 0.62),
                   Color(red: 0.98, green: 0.6, blue: 0.24), Color(red: 0.64, green: 0.5, blue: 0.93)]

/// The four heaviest contributions, the rest as "Other", each with its color in the bar and legend.
func slices(_ s: Store) -> [(label: String, liters: Double, color: Color)] {
    let all = s.bySource
    var out = all.prefix(sliceColors.count).enumerated().map { ($1.label, $1.water.mid, sliceColors[$0]) }
    let rest = all.dropFirst(sliceColors.count).reduce(0) { $0 + $1.water.mid }
    if rest > 0 { out.append(("Other", rest, .gray)) }
    return out.filter { $0.1 > 0 }
}

func tips(_ s: Store) -> [String] {
    var out: [String] = []
    if let top = s.byModel.first, top.model.provider == "anthropic", let haiku = catalog["claude-haiku-5-5"], top.model.name != haiku.name {
        let ratio = EcoLogits.water(top.model, outputTokens: 1000).mid / EcoLogits.water(haiku, outputTokens: 1000).mid
        if ratio >= 2 { out.append("Try Haiku: ~\(Int(ratio))× less water") }
    }
    let output = s.recent.reduce(0) { $0 + $1.output }, thinking = s.recent.reduce(0) { $0 + $1.thinking }
    if output > 0, thinking * 10 > output * 3 { out.append("Try lower effort: \(thinking * 100 / output)% is thinking") }
    out.append("Shorter answers, less water")
    out.append("Skip AI Overviews: add &udm=14")
    return out
}

// MARK: - Pixel art

enum Sprites {
    // # body, % shade, e eye, b blush, m mouth, . container inside, space transparent
    static let awake = [
        "     ##     ", "    ####    ", "   ######   ", "  ########  ", " ########## ", " ##e####e## ",
        "###e####e###", "##b######b##", "#####mm#####", " %%%%%%%%%% ", "  %%%%%%%%  ",
    ]
    static let asleep = awake.enumerated().map { i, r in
        i == 5 ? " ########## " : i == 6 ? "##ee####ee##" : r
    }
    static let cup = ["#....#  ", "#....###", "#....# #", "#....###", " ####   "]
    static let bottle = ["  ##  ", " #..# ", "#....#", "#....#", "#....#", " #### "]
    static let toilet = ["###    ", "#.#    ", "#.#####", "#.....#", " #...# ", "  ###  "]
    static let bucket = [" #### ", "#    #", "######", "#....#", " #..# ", " #### "]
    static let shower = ["  ### ", " #   #", " # ###", " #  . ", " # . .", " #  . ", "###   "]
    static let tub = ["#         ", "##########", "#........#", " #......# ", "  ######  "]
}

struct Palette {
    let scheme: ColorScheme
    var warmth = 0.0   // 0 = cool blue, 1 = fully overheated
    var card: Color { scheme == .dark ? Color(white: 0.15) : .white }
    var track: Color { scheme == .dark ? Color(white: 0.27) : Color(white: 0.91) }
    var ground: Color { scheme == .dark ? Color(white: 0.35) : Color(white: 0.82) }
    var ink: Color { scheme == .dark ? Color(white: 0.92) : Color(white: 0.15) }
    var bubble: Color { scheme == .dark ? Color(white: 0.24) : Color(white: 0.97) }
    var outline: Color { scheme == .dark ? Color(white: 0.6) : Color(white: 0.45) }
    var water: Color { mix((0.33, 0.62, 0.96), (0.96, 0.47, 0.36)) }
    var shade: Color { mix((0.2, 0.45, 0.82), (0.8, 0.3, 0.25)) }
    let eye = Color(red: 0.1, green: 0.12, blue: 0.18)
    var blush: Color { Color(red: 1, green: 0.5, blue: 0.55).opacity(0.6 + 0.4 * warmth) }

    private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Color {
        Color(red: a.0 + (b.0 - a.0) * warmth, green: a.1 + (b.1 - a.1) * warmth, blue: a.2 + (b.2 - a.2) * warmth)
    }
}

func draw(_ rows: [String], in ctx: GraphicsContext, at o: CGPoint, px: CGFloat, ink: Color, fill: Double = 0, _ p: Palette) {
    let inside = rows.indices.filter { rows[$0].contains(".") }
    let wet = Set(inside.suffix(Int((fill * Double(inside.count)).rounded(.up))))
    for (y, row) in rows.enumerated() {
        for (x, ch) in row.enumerated() {
            let c: Color? = switch ch {
            case "#": ink
            case "%": p.shade
            case "e", "m": p.eye
            case "b": p.blush
            case ".": wet.contains(y) ? p.water : nil
            default: nil
            }
            if let c { ctx.fill(Path(CGRect(x: o.x + CGFloat(x) * px, y: o.y + CGFloat(y) * px, width: px, height: px)), with: .color(c)) }
        }
    }
}

// MARK: - Companion

/// Tracky on its ground line. Asleep when Claude is idle, pacing and hopping while it works.
/// Heat (0–5, one per container passed) layers on top: blush, sweat, flushed cheeks and panting, steam, then a red body.
struct Scene: View {
    let asleep: Bool, heat: Int, tick: Int, tip: String?
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Canvas { ctx, size in render(ctx, size) }.frame(height: 100)
    }

    private func render(_ ctx: GraphicsContext, _ size: CGSize) {
        let p = Palette(scheme: scheme, warmth: heat >= 5 ? 0.75 : 0)   // blue until overheated: a blue–red blend reads as purple
        let px: CGFloat = 4, groundY = size.height - 4, w = 12 * px, h = 11 * px
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: size.width, height: 1)), with: .color(p.ground))

        let period = 40 - heat * 5   // paces faster as it heats up
        let phase = Double(tick % period) / Double(period)
        let x = asleep ? (size.width - w) / 2 : 12 + (size.width - w - 24) * (0.5 - 0.5 * cos(phase * 2 * .pi))
        let y = groundY - h - (!asleep && tick % 2 == 0 ? 3 : 0)
        func dot(_ dx: CGFloat, _ dy: CGFloat, _ c: Color, _ s: CGFloat = 3, _ t: CGFloat = 3) {
            ctx.fill(Path(CGRect(x: x + dx, y: y + dy, width: s, height: t)), with: .color(c))
        }

        var rows = asleep ? Sprites.asleep : Sprites.awake
        if heat == 0 { rows = rows.map { $0.replacingOccurrences(of: "b", with: "#") } }   // cool: no blush yet
        if heat >= 3 { rows[7] = "#bb######bb#" }                                            // hot: flushed cheeks
        draw(rows, in: ctx, at: CGPoint(x: x, y: y), px: px, ink: p.water, p)
        if heat >= 3 && tick % 2 == 0 { dot(5 * px, 9 * px, p.eye, 2 * px, px) }        // panting

        let sweat: [(CGFloat, CGFloat)] = [(-5, 14), (w + 2, 8), (-6, 2), (w + 3, 22)]
        for (sx, sy) in sweat.prefix(max(heat - 1, 0)) { dot(sx, sy + CGFloat(tick % 3) * 2, Color(red: 0.45, green: 0.75, blue: 1), 3, 5) }
        if heat >= 4 {
            for i in 0..<3 { dot(w / 2 - 12 + CGFloat(i) * 10, -6 - CGFloat((tick + i * 3) % 9) * 2, p.ground.opacity(0.8)) }
        }

        if !asleep {   // dust kicks up behind it
            let back: CGFloat = sin(phase * 2 * .pi) > 0 ? -1 : 1
            ctx.fill(Path(CGRect(x: back < 0 ? x - 6 : x + w + 2, y: groundY - 3 - CGFloat(tick % 2) * 3, width: 3, height: 3)),
                     with: .color(p.ground))
        }

        if let tip {
            let text = ctx.resolve(Text(tip).font(.system(size: 11, weight: .medium)).foregroundColor(p.ink))
            let ts = text.measure(in: CGSize(width: size.width - 16, height: 40))
            let bw = ts.width + 16, bh = ts.height + 10
            let box = CGRect(x: min(max(x + w / 2 - bw / 2, 0), size.width - bw), y: 0, width: bw, height: bh)
            let tx = min(max(x + w / 2, box.minX + 12), box.maxX - 12)
            var tail = Path()
            tail.move(to: CGPoint(x: tx - 5, y: box.maxY - 0.5))
            tail.addLine(to: CGPoint(x: tx, y: box.maxY + 7))
            tail.addLine(to: CGPoint(x: tx + 5, y: box.maxY - 0.5))
            ctx.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(p.bubble))
            ctx.stroke(Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8), with: .color(p.ground), lineWidth: 1)
            ctx.fill(tail, with: .color(p.bubble))
            ctx.stroke(tail, with: .color(p.ground), lineWidth: 1)
            ctx.draw(text, in: box.insetBy(dx: 8, dy: 5))
        } else if asleep {
            for i in 0..<2 {
                ctx.draw(Text("z").font(.system(size: CGFloat(10 + 3 * i), weight: .bold, design: .monospaced)).foregroundColor(p.ground),
                         at: CGPoint(x: x + w + 4 + CGFloat(i) * 9, y: y - 2 - CGFloat(i) * 9 - CGFloat(tick % 6)))
            }
        }
    }
}

struct Companion: View {
    @ObservedObject var store: Store
    var forced: (asleep: Bool, heat: Int)? = nil   // for --preview
    @State private var tick = 0
    @Environment(\.colorScheme) var scheme
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = Palette(scheme: scheme), total = store.total.mid
        let c = forced.map { (containers[$0.heat].name, containers[$0.heat].sprite, 0.6, $0.heat) } ?? container(for: total)
        let tipList = tips(store), secs = tick / 4
        let tip = secs % 24 < 8 ? tipList[(secs / 24) % tipList.count] : nil   // speaks for 8 s every 24 s
        VStack(alignment: .leading, spacing: 10) {
            Scene(asleep: forced?.asleep ?? !store.active, heat: c.3, tick: tick, tip: tip)
            HStack(alignment: .firstTextBaseline) {
                Text("Water").font(.system(size: 14, weight: .semibold))
                Text("last \(Int(store.hours))h").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("≈ " + fmt(total)).font(.system(size: 15, weight: .bold)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.track)
                    Capsule().fill(p.water).frame(width: max(g.size.width * c.2, c.2 > 0 ? 8 : 0))
                }
            }
            .frame(height: 8)
            HStack(spacing: 6) {
                Canvas { ctx, _ in draw(c.1, in: ctx, at: .zero, px: 2, ink: p.outline, fill: c.2, p) }
                    .frame(width: CGFloat(c.1.map(\.count).max() ?? 0) * 2, height: CGFloat(c.1.count) * 2)
                Text("\(Int(c.2 * 100))% of a \(c.0)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            let parts = slices(store), sum = parts.reduce(0) { $0 + $1.liters }
            if sum > 0 {
                Divider()
                GeometryReader { g in   // the whole bar is the total; each slice is one model and source
                    HStack(spacing: 2) {
                        ForEach(parts.indices, id: \.self) { i in
                            Rectangle().fill(parts[i].color)
                                .frame(width: max((g.size.width - CGFloat(parts.count - 1) * 2) * parts[i].liters / sum, 2))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(parts.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(parts[i].color).frame(width: 8, height: 8)
                            Text(parts[i].label).lineLimit(1)
                            Spacer()
                            Text(fmt(parts[i].liters)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 18).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
        .onReceive(timer) { _ in if forced == nil { tick += 1 } }
    }
}

// MARK: - App

/// Borderless panel dragged from anywhere (SwiftUI content would otherwise swallow the click).
final class DragPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { performDrag(with: event) } else { super.sendEvent(event) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    var panel: DragPanel!
    var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_: Notification) {
        store.start()
        // Open at login by default, once; the menu switch turns it off for good.
        if !UserDefaults.standard.bool(forKey: "loginSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSet")
        }

        let host = NSHostingView(rootView: Companion(store: store))
        panel = DragPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !panel.setFrameUsingName("companion") { panel.center() }
        panel.setFrameAutosaveName("companion")
        if UserDefaults.standard.object(forKey: "showCompanion") as? Bool ?? true { panel.orderFront(nil) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = dropIcon()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu()
        statusItem.menu?.autoenablesItems = false
        statusItem.menu?.delegate = self
        // @Published fires before the new value is stored, so read the total on the next run-loop turn.
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            statusItem.button?.title = " " + fmt(store.total.mid)
            // The legend grows and shrinks the card; keep its top edge where the user left it.
            if let host = panel.contentView, host.fittingSize.height != panel.frame.height {
                var f = panel.frame
                f.origin.y += f.height - host.fittingSize.height
                f.size = host.fittingSize
                panel.setFrame(f, display: true)
            }
        }.store(in: &bag)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(row("Water · last \(Int(store.hours))h", "≈ " + fmt(store.total.mid), bold: true))
        for m in store.bySource.prefix(5) { menu.addItem(row(m.label, fmt(m.water.mid))) }
        if store.bySource.isEmpty { menu.addItem(row("No AI activity yet", "")) }
        menu.addItem(.separator())
        menu.addItem(row("💡 " + tips(store)[0], ""))
        menu.addItem(.separator())

        let period = NSMenuItem(title: "Period", action: nil, keyEquivalent: "")
        period.submenu = NSMenu()
        for h in [1, 5, 24] {
            let i = NSMenuItem(title: "Last \(h) hour\(h == 1 ? "" : "s")", action: #selector(setHours(_:)), keyEquivalent: "")
            i.target = self; i.tag = h; i.state = Int(store.hours) == h ? .on : .off
            period.submenu?.addItem(i)
        }
        menu.addItem(period)
        let show = NSMenuItem(title: "Show on desktop", action: #selector(toggleCompanion), keyEquivalent: "")
        show.target = self; show.state = panel.isVisible ? .on : .off
        menu.addItem(show)
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let how = NSMenuItem(title: "How is this estimated?", action: #selector(openMethodology), keyEquivalent: "")
        how.target = self
        menu.addItem(how)
        menu.addItem(NSMenuItem(title: "Quit Tracky", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    /// A read-only line with the value right-aligned.
    private func row(_ left: String, _ right: String, bold: Bool = false) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let i = NSMenuItem(title: left, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: right.isEmpty ? left : "\(left)\t\(right)", attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.menuFont(ofSize: 13), .paragraphStyle: style,
        ])
        return i
    }

    @objc func setHours(_ sender: NSMenuItem) { store.hours = Double(sender.tag) }
    /// The EcoLogits method Tracky implements.
    @objc func openMethodology() { NSWorkspace.shared.open(URL(string: "https://ecologits.ai/latest/methodology/llm_inference/")!) }
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        try? s.status == .enabled ? s.unregister() : s.register()
    }
    @objc func toggleCompanion() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFront(nil)
        UserDefaults.standard.set(panel.isVisible, forKey: "showCompanion")
    }

    /// The drop sprite as a template image for the menu bar.
    private func dropIcon() -> NSImage {
        let rows = Sprites.awake, px: CGFloat = 1.4
        let img = NSImage(size: NSSize(width: 12 * px, height: 11 * px), flipped: true) { _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where "#%b".contains(ch) {
                    NSRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--selftest") { selfTest(catalog: catalog); browserSelfTest(catalog: catalog); exit(0) }
if args.contains("--dump") {   // what Tracky sees in the last 24 h
    for (name, us) in Dictionary(grouping: Store().load(), by: { $0.model.name }) {
        let w = us.reduce(Liters()) { $0 + $1.water }
        print(name, us.count, "requests", us.reduce(0) { $0 + $1.output }, "output tokens", fmt(w.min), "–", fmt(w.max))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {   // render every heat level, awake (light) and asleep (dark), to a PNG
    let store = Store()
    // Real usage plus a few sample browser events, so the legend shows every kind of source.
    let samples = [#"{"site":"claude.ai","model":"claude-sonnet-5-5","tokens":4000}"#, #"{"site":"chatgpt.com","model":"gpt-5-2","tokens":3000}"#]
        + Array(repeating: #"{"site":"google-ai-overview"}"#, count: 40)
    store.usages = store.load() + samples.compactMap { BrowserEvent(json: Data($0.utf8))?.usage(at: Date(), catalog: catalog) }
    let sheet = VStack(spacing: 16) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            HStack(alignment: .top, spacing: 16) {   // light: awake at each heat level; dark: asleep
                ForEach(0..<containers.count, id: \.self) { Companion(store: store, forced: (scheme == .dark, $0)) }
            }
            .padding(16).background(scheme == .dark ? Color(white: 0.05) : Color(white: 0.86)).environment(\.colorScheme, scheme)
        }
    }
    let png = MainActor.assumeIsolated { () -> Data? in   // top-level code runs on the main thread
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        return r.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }
    guard let png else { exit(1) }
    try png.write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
