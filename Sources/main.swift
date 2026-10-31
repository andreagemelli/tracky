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
    @Published var browserOn = ChromeLink.on
    @Published var chromeConnected = ChromeLink.connected
    @Published var showSetup = false
    @Published var roasting = false
    @Published var metric = Metric(rawValue: UserDefaults.standard.string(forKey: "metric") ?? "") ?? .water {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "metric") }
    }
    func refreshLink() { browserOn = ChromeLink.on; chromeConnected = ChromeLink.connected }
    @Published var compact = UserDefaults.standard.bool(forKey: "compact") {
        didSet { UserDefaults.standard.set(compact, forKey: "compact") }
    }
    @Published var hours: Double = UserDefaults.standard.object(forKey: "hours") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(hours, forKey: "hours") }
    }
    private let reader = ClaudeCodeReader(), browser = BrowserReader(), local = LocalReader(), llama = LlamaCpp()
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
            + local.read(since: cutoff)
        return kept
    }

    private func refresh() {
        queue.async { [self] in
            llama.poll()
            let all = load()
            DispatchQueue.main.async { self.usages = all; self.refreshLink() }
        }
    }

    var recent: [Usage] { usages.filter { $0.date > Date().addingTimeInterval(-hours * 3600) } }
    var impact: Impact { recent.reduce(Impact()) { $0 + $1.impact } }
    var total: Amount { metric.of(impact) }
    var active: Bool { usages.contains { $0.date > Date().addingTimeInterval(-90) } }

    /// One metric per model and source (Google's surfaces by name), heaviest first.
    func bySource(_ m: Metric) -> [(label: String, value: Amount)] {
        Dictionary(grouping: recent) { $0.model.provider == "google" ? $0.model.name : "\(pretty($0.model.name)) · \($0.source)" }
            .map { ($0.key, m.of($0.value.reduce(Impact()) { $0 + $1.impact })) }
            .sorted { $0.value.mid > $1.value.mid }
    }
}

// MARK: - Wording

func pretty(_ name: String) -> String {
    if name.first?.isUppercase == true { return name }   // already a display name, e.g. "Google AI Overview"
    return name.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1.$2", options: .regularExpression)
        .replacingOccurrences(of: "-", with: " ").capitalized
        .replacingOccurrences(of: "Gpt", with: "GPT")
}

let sliceColors = [Color(red: 0.33, green: 0.62, blue: 0.96), Color(red: 0.2, green: 0.74, blue: 0.62),
                   Color(red: 0.98, green: 0.6, blue: 0.24), Color(red: 0.64, green: 0.5, blue: 0.93),
                   Color(red: 0.94, green: 0.45, blue: 0.62)]

/// At most five lines for the bar, the legend and the menu: all of them if they fit, else the four
/// heaviest and "Other" summing the rest.
func slices(_ s: Store, _ m: Metric) -> [(label: String, amount: Double, color: Color)] {
    let all = s.bySource(m).filter { $0.value.mid > 0 }
    let named = all.count <= 5 ? all[...] : all.prefix(4)
    var out = named.enumerated().map { ($1.label, $1.value.mid, sliceColors[$0]) }
    if all.count > 5 { out.append(("Other", all.dropFirst(4).reduce(0) { $0 + $1.value.mid }, .gray)) }
    return out
}

/// The next lighter model of the same family, for "try a smaller model" tips. First match wins.
func lighter(than m: Model) -> Model? {
    let steps = [("claude-fable", "claude-opus-5-5"), ("claude-opus", "claude-sonnet-5-5"), ("claude-sonnet", "claude-haiku-5-5"),
                 ("gpt-5-mini", "gpt-5-nano"), ("gpt-5", "gpt-5-mini")]
    guard let alt = steps.first(where: { m.name.hasPrefix($0.0) }).flatMap({ catalog[$0.1] }), alt.name != m.name else { return nil }
    return alt
}

/// A local model's footprint per 1,000 output tokens, in `metric`: as this Mac measured it, else
/// 30 tokens/s at `localWatts` on the region's grid.
func localPer1k(_ s: Store, _ metric: Metric) -> Double {
    let local = s.usages.filter { $0.model.provider == "local" }, n = local.reduce(0) { $0 + $1.output }
    if n > 0 { return metric.of(local.reduce(Impact()) { $0 + $1.impact }).mid / Double(n) * 1000 }
    // ponytail: 30 tokens/s is a typical 8B model on Apple silicon; bigger local models run slower and draw more.
    return metric.of(.fromEnergy(kWh: 1000 / 30 * localWatts / 3_600_000, kgCO2PerKWh: localGrid.kgCO2PerKWh,
                                 litersPerKWh: localGrid.litersPerKWh)).mid
}

/// Tips from recent activity, most relevant first: whether AI was needed at all, then a smaller or a
/// local model (always one of them), then lower effort. Kept under ~32 characters for the speech bubble.
func tips(_ s: Store, _ metric: Metric) -> [String] {
    var out: [String] = []
    let hour = s.usages.filter { $0.date > Date().addingTimeInterval(-3600) }
    let chats = hour.filter { $0.source != "Code" && $0.model.provider != "local" }
    if let last = s.usages.max(by: { $0.date < $1.date }) {
        // Was AI needed? Google's AI answers, many asks in an hour, or mostly short replies (quick facts).
        if last.source == "Search" {
            out += ["A plain search would do?", "Try Google's Web tab: no AI"]
        } else if chats.count >= 15 {
            out += ["\(chats.count) asks this hour. All needed?", "Really need AI for this?"]
        } else if chats.count >= 3, chats.map(\.output).sorted()[chats.count / 2] < 150 {
            out += ["Quick facts? A search will do", "Really need AI for this?"]
        }
        if hour.filter({ $0.source == "Code" }).count >= 200 { out.append("Long agent run? Scope it tighter") }

        // Smaller or local: always suggest one.
        if last.model.provider == "local" {
            out.append("Local model: the lightest way 👍")
        } else {
            let one = { (m: Model) in metric.of(EcoLogits.impact(m, outputTokens: 1000)).mid }
            if let alt = lighter(than: last.model), case let r = one(last.model) / one(alt), r >= 1.5 {
                out.append("Try \(pretty(alt.name)): ~\(Int(r.rounded()))× less \(metric.noun)")
            }
            let local = localPer1k(s, metric) * Double(last.output) / 1000
            if local > 0, case let r = metric.of(last.impact).mid / local, r >= 1.5 {
                out.append("Local model: ~\(Int(r.rounded()))× less \(metric.noun)")
            } else if lighter(than: last.model) == nil {
                out.append("A smaller model may do")
            }
        }

        if let effort = last.effort, ["max", "xhigh", "high"].contains(effort) {
            let code = s.recent.filter { $0.source == "Code" }
            let output = code.reduce(0) { $0 + $1.output }, thinking = code.reduce(0) { $0 + $1.thinking }
            out.append(output > 0 && thinking * 10 > output * 3 ? "\(thinking * 100 / output)% thinking: try lower effort"
                                                               : "Effort \(effort): try lower")
        }
    }
    out.append("Shorter answers, less \(metric.noun)")
    return out
}

func tipsSelfTest() {
    func step(_ from: String) -> String? { catalog[from].flatMap(lighter(than:))?.name }
    precondition(step("claude-opus-5-5") == "claude-sonnet-5-5" && step("claude-sonnet-4-5-20250929") == "claude-haiku-5-5")
    precondition(step("claude-haiku-5-5") == nil, "Haiku is the lightest Claude")
    precondition(step("gpt-5.2") == "gpt-5-mini" && step("gpt-5-mini") == "gpt-5-nano")

    let s = Store(), sonnet = catalog["claude-sonnet-5-5"]!, haiku = catalog["claude-haiku-5-5"]!
    func chat(_ m: Model, _ tokens: Int) -> Usage {
        Usage(date: Date(), source: "claude.ai", model: m, output: tokens, thinking: 0, effort: nil, impact: EcoLogits.impact(m, outputTokens: tokens))
    }
    s.usages = Array(repeating: chat(sonnet, 800), count: 15)
    let busy = tips(s, .water)
    precondition(busy[0] == "15 asks this hour. All needed?" && busy.contains { $0.hasPrefix("Try Haiku 5.5") }
                 && busy.contains { $0.hasPrefix("Local model: ~") }, "got \(busy)")
    s.usages = Array(repeating: chat(haiku, 60), count: 4)   // short replies from the lightest Claude
    let quick = tips(s, .energy)
    // Batched data-center GPUs beat a laptop on energy for a model as small as Haiku: no local tip, a smaller one instead.
    precondition(quick[0] == "Quick facts? A search will do" && quick.contains("A smaller model may do"), "got \(quick)")
    s.usages = [chat(sonnet, 800)]
    precondition(!tips(s, .co2).contains { $0.contains("search") || $0.contains("need") }, "one ask is no reason to nag")
    print("tips selftest ok")
}

// MARK: - Pixel art

enum Sprites {
    // # body, % shade, e eye, b blush, m mouth, . container inside, space transparent
    /// Tracky: the metric's own top (drop, spark or fire) over a shared face and body.
    static func awake(_ m: Metric) -> [String] {
        m.top + ["  ########  ", " ########## ", " ##e####e## ", "###e####e###", "##b######b##", "#####mm#####", " %%%%%%%%%% ", "  %%%%%%%%  "]
    }
    static func angry(_ m: Metric) -> [String] {   // thick brows, red cheeks, a frown
        awake(m).enumerated().map { i, r in i == 4 ? " #ee####ee# " : i == 7 ? "#bb######bb#" : i == 8 ? "####mmmm####" : r }
    }
    static func asleep(_ m: Metric) -> [String] {
        awake(m).enumerated().map { i, r in i == 5 ? " ########## " : i == 6 ? "##ee####ee##" : r }
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
    var warmth = 0.0   // 0 = the metric's own color, 1 = fully overheated
    var metric = Metric.water
    var card: Color { scheme == .dark ? Color(white: 0.15) : .white }
    var track: Color { scheme == .dark ? Color(white: 0.27) : Color(white: 0.91) }
    var ground: Color { scheme == .dark ? Color(white: 0.35) : Color(white: 0.82) }
    var ink: Color { scheme == .dark ? Color(white: 0.92) : Color(white: 0.15) }
    var bubble: Color { scheme == .dark ? Color(white: 0.24) : Color(white: 0.97) }
    var outline: Color { scheme == .dark ? Color(white: 0.6) : Color(white: 0.45) }
    var body: Color { mix(metric.tint, (0.96, 0.47, 0.36)) }
    var shade: Color { mix(metric.shadeTint, (0.8, 0.3, 0.25)) }
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
            case ".": wet.contains(y) ? p.body : nil
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
    var metric = Metric.water
    var angry = false   // roasting: red, shaking and steaming whatever the heat
    var height: CGFloat = 100
    var rightMargin: CGFloat = 0   // room left free for the card's corner icons
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Canvas { ctx, size in render(ctx, size) }.frame(height: height)
    }

    private func render(_ ctx: GraphicsContext, _ size: CGSize) {
        // Its own color until overheated: a blend toward red reads as muddy halfway.
        let p = Palette(scheme: scheme, warmth: heat >= 5 || angry ? 0.75 : 0, metric: metric)
        let px: CGFloat = 4, groundY = size.height - 4, w = 12 * px, h = 11 * px
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: size.width, height: 1)), with: .color(p.ground))

        let period = 40 - heat * 5   // paces faster as it heats up
        let phase = Double(tick % period) / Double(period)
        let x = angry ? (size.width - w) / 2 + (tick % 2 == 0 ? -2 : 2)
            : asleep ? (size.width - w) / 2 : 12 + (size.width - w - 24 - rightMargin) * (0.5 - 0.5 * cos(phase * 2 * .pi))
        let y = groundY - h - (!asleep && !angry && tick % 2 == 0 ? 3 : 0)
        func dot(_ dx: CGFloat, _ dy: CGFloat, _ c: Color, _ s: CGFloat = 3, _ t: CGFloat = 3) {
            ctx.fill(Path(CGRect(x: x + dx, y: y + dy, width: s, height: t)), with: .color(c))
        }

        var rows = angry ? Sprites.angry(metric) : asleep ? Sprites.asleep(metric) : Sprites.awake(metric)
        if heat == 0 { rows = rows.map { $0.replacingOccurrences(of: "b", with: "#") } }   // cool: no blush yet
        if heat >= 3 { rows[7] = "#bb######bb#" }                                            // hot: flushed cheeks
        draw(rows, in: ctx, at: CGPoint(x: x, y: y), px: px, ink: p.body, p)
        if heat >= 3 && tick % 2 == 0 { dot(5 * px, 9 * px, p.eye, 2 * px, px) }        // panting

        if metric == .energy {   // the spark crackles: small zigzags beside its head, flickering
            let zap = Color(red: 1, green: 0.93, blue: 0.45)
            for (sx, flip) in [(CGFloat(-9), tick % 2 == 0), (w + 3, tick % 2 == 1)] where flip || !asleep {
                for (i, dx) in [0, 3, 0, 3].enumerated() { dot(sx + CGFloat(dx), 2 + CGFloat(i) * 3, zap, 3, 3) }
            }
        }
        let sweat: [(CGFloat, CGFloat)] = [(-5, 14), (w + 2, 8), (-6, 2), (w + 3, 22)]
        for (sx, sy) in sweat.prefix(max(heat - 1, 0)) { dot(sx, sy + CGFloat(tick % 3) * 2, Color(red: 0.45, green: 0.75, blue: 1), 3, 5) }
        if heat >= 4 || angry {
            for i in 0..<3 { dot(w / 2 - 12 + CGFloat(i) * 10, -6 - CGFloat((tick + i * 3) % 9) * 2, p.ground.opacity(0.8)) }
        }

        if !asleep && !angry {   // dust kicks up behind it
            let back: CGFloat = sin(phase * 2 * .pi) > 0 ? -1 : 1
            ctx.fill(Path(CGRect(x: back < 0 ? x - 6 : x + w + 2, y: groundY - 3 - CGFloat(tick % 2) * 3, width: 3, height: 3)),
                     with: .color(p.ground))
        }

        if let tip {
            let text = ctx.resolve(Text(tip).font(.system(size: 11, weight: .medium)).foregroundColor(p.ink))
            let ts = text.measure(in: CGSize(width: size.width - rightMargin - 16, height: 40))
            let bw = ts.width + 16, bh = ts.height + 10
            let box = CGRect(x: min(max(x + w / 2 - bw / 2, 0), size.width - rightMargin - bw), y: 0, width: bw, height: bh)
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
    var forcedCompact: Bool? = nil
    var forcedMetric: Metric? = nil
    var window: () -> NSWindow? = { nil }
    @State private var tick = 0
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @Environment(\.colorScheme) var scheme
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let metric = forcedMetric ?? store.metric, impact = store.impact, total = metric.of(impact).mid
        let p = Palette(scheme: scheme, metric: metric)
        let c = forced.map { (rung: metric.ladder[$0.heat], fill: 0.6, level: $0.heat) } ?? rung(for: total, metric)
        let tipList = tips(store, metric), secs = tick / 4, compact = forcedCompact ?? store.compact
        let roasting = store.roasting && !compact, angry = roasting
        let tip = roasting ? metric.shouts[(secs / 3) % metric.shouts.count]
            : secs % 24 < 8 ? tipList[(secs / 24) % tipList.count] : nil   // speaks for 8 s every 24 s
        VStack(alignment: .leading, spacing: 10) {
            Scene(asleep: (forced?.asleep ?? !store.active) && !angry, heat: c.level, tick: tick, tip: compact ? nil : tip,
                  metric: metric, angry: angry, height: compact ? 64 : 100, rightMargin: compact ? 0 : 22)
            if roasting { RoastView(store: store, metric: metric) } else if store.showSetup && !compact { BrowserSetup(store: store) }
            if compact {   // minimal: Tracky, the total and where most of it came from
                VStack(spacing: 2) {
                    Text("≈ " + metric.fmt(total)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    if let top = slices(store, metric).first {
                        Text(top.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if !roasting {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(metric.name).font(.system(size: 14, weight: .semibold))
                        Text("last \(Int(store.hours))h").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text("≈ " + metric.fmt(total)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    }
                    Text(others(metric, impact)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.track)
                        Capsule().fill(p.body).frame(width: max(g.size.width * c.fill, c.fill > 0 ? 8 : 0))
                    }
                }
                .frame(height: 8)
                HStack(spacing: 6) {
                    if let sprite = c.rung.sprite {
                        Canvas { ctx, _ in draw(sprite, in: ctx, at: .zero, px: 2, ink: p.outline, fill: c.fill, p) }
                            .frame(width: CGFloat(sprite.map(\.count).max() ?? 0) * 2, height: CGFloat(sprite.count) * 2)
                    } else if let symbol = c.rung.symbol {
                        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(p.outline)
                    }
                    Text("\(Int(c.fill * 100))% of \(c.rung.name)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                let parts = slices(store, metric), sum = parts.reduce(0) { $0 + $1.amount }
                if sum > 0 {
                    Divider()
                    GeometryReader { g in   // the whole bar is the total; each slice is one model and source
                        HStack(spacing: 2) {
                            ForEach(parts.indices, id: \.self) { i in
                                Rectangle().fill(parts[i].color)
                                    .frame(width: max((g.size.width - CGFloat(parts.count - 1) * 2) * parts[i].amount / sum, 2))
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
                                Text(metric.fmt(parts[i].amount)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
            }
        }
        .padding(compact ? 12 : 16)
        .frame(width: compact ? 150 : 250)
        .background(RoundedRectangle(cornerRadius: 18).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
        // Drag from anywhere that isn't a button; double-click switches minimal and complete.
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(count: 2) { store.compact.toggle() }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { _ in
                guard let w = window() else { return }
                let m = NSEvent.mouseLocation, s = dragStart ?? (m, w.frame.origin)
                dragStart = s
                w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y))
            }
            .onEnded { _ in dragStart = nil })
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Browser tracking status: red off, green on. Only the full card opens the setup.
                let globe = Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(store.browserOn ? Color.green : Color.red).frame(width: 6, height: 6).offset(x: 2, y: 2)
                    }
                    .padding(10).contentShape(Rectangle())
                if compact {
                    globe.help(store.browserOn ? "Browser tracking is on" : "Browser tracking is off")
                } else {
                    Button { store.roasting = false; store.showSetup.toggle() } label: { globe }
                        .buttonStyle(.plain)
                        .help(store.browserOn ? "Browser tracking is on" : "Browser tracking is off · click to set up")
                    // Roast: the card swaps to funny equivalents of the chosen metric.
                    Button { store.showSetup = false; store.roasting.toggle() } label: {
                        Image(systemName: "flame.fill").font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 10).padding(.bottom, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Roast me")
                    // Switch what Tracky tracks: water → energy → CO₂.
                    let next = Metric.allCases[(Metric.allCases.firstIndex(of: metric)! + 1) % Metric.allCases.count]
                    Button { store.metric = next } label: {
                        Image(systemName: metric.symbol).font(.system(size: 12))
                            .foregroundStyle(Color(red: metric.tint.0, green: metric.tint.1, blue: metric.tint.2))
                            .padding(.horizontal, 10).padding(.bottom, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Tracking \(metric.noun) · click for \(next.noun)")
                }
            }
        }
        .onReceive(timer) { _ in if forced == nil { tick += 1 } }
    }
}

/// The two metrics not chosen, reported on the side: "Energy 12 Wh · CO₂ 4.6 g".
func others(_ metric: Metric, _ impact: Impact) -> String {
    Metric.allCases.filter { $0 != metric }.map { "\($0.name) \($0.fmt($0.of(impact).mid))" }.joined(separator: " · ")
}

/// The roast: Tracky is furious and lists what the same amount could have been instead.
struct RoastView: View {
    @ObservedObject var store: Store
    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("≈ \(metric.fmt(metric.of(store.impact).mid)) could have been…").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.roasting = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            let items = metric.roast, total = metric.of(store.impact).mid
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(items[i].emoji)
                    Text(roastLine(items[i], total)).font(.system(size: 12))
                }
            }
        }
    }
}

/// Two steps to count AI in Chrome, shown inside the card from the globe or the menu.
struct BrowserSetup: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Browser tracking").font(.system(size: 12, weight: .semibold))
                Text(store.browserOn ? "on" : "off").font(.system(size: 11)).foregroundStyle(store.browserOn ? .green : .red)
                Spacer()
                Button { store.showSetup = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if store.browserOn {
                HStack {
                    Text("Counting AI replies in Chrome").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn off") { ChromeLink.disconnect(); store.refreshLink() }
                }
            } else if ChromeLink.chrome == nil {
                Text("Needs Google Chrome").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                step(1, "Connect Chrome", done: store.chromeConnected) {
                    Button(store.chromeConnected ? "Done" : "Connect") { ChromeLink.connect(); store.refreshLink() }.disabled(store.chromeConnected)
                }
                step(2, "Add the extension", note: "Developer mode → Load unpacked", done: false) {
                    Button("Open") { ChromeLink.showExtension() }.disabled(!store.chromeConnected)
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func step(_ n: Int, _ title: String, note: String? = nil, done: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer()
            action()
        }
    }
}

// MARK: - App

/// Takes the first click even though Tracky never becomes the active app, so the card's buttons work.
final class FirstClickHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_: Notification) {
        store.start()
        // Open at login by default, once; the menu switch turns it off for good.
        if !UserDefaults.standard.bool(forKey: "loginSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSet")
        }

        let host = FirstClickHost(rootView: Companion(store: store, window: { [weak self] in self?.panel }))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
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
        statusItem.button?.image = trackyIcon(store.metric)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu()
        statusItem.menu?.autoenablesItems = false
        statusItem.menu?.delegate = self
        // @Published fires before the new value is stored, so read the total on the next run-loop turn.
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            statusItem.button?.image = trackyIcon(store.metric)
            statusItem.button?.title = " " + store.metric.fmt(store.total.mid)
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
        let m = store.metric
        menu.addItem(row("\(m.name) · last \(Int(store.hours))h", "≈ " + m.fmt(store.total.mid), bold: true))
        menu.addItem(row(others(m, store.impact), ""))
        menu.addItem(.separator())
        for slice in slices(store, m) { menu.addItem(row(slice.label, m.fmt(slice.amount))) }
        if slices(store, m).isEmpty { menu.addItem(row("No AI activity yet", "")) }
        menu.addItem(.separator())
        menu.addItem(row("💡 " + tips(store, m)[0], ""))
        menu.addItem(.separator())

        let browser = NSMenuItem(title: store.browserOn ? "Browser tracking: on" : "Browser tracking: off · Set up…",
                                 action: #selector(openBrowserSetup), keyEquivalent: "")
        browser.target = self
        browser.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(browser)
        menu.addItem(.separator())

        let track = NSMenuItem(title: "Track", action: nil, keyEquivalent: "")
        track.submenu = NSMenu()
        for (i, metric) in Metric.allCases.enumerated() {
            let item = NSMenuItem(title: metric.name, action: #selector(setMetric(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.state = metric == m ? .on : .off
            item.image = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: nil)
            track.submenu?.addItem(item)
        }
        menu.addItem(track)
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
        let minimal = NSMenuItem(title: "Minimal card", action: #selector(toggleCompact), keyEquivalent: "")
        minimal.target = self; minimal.state = store.compact ? .on : .off
        menu.addItem(minimal)
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let how = NSMenuItem(title: "How is this estimated?", action: #selector(openMethodology), keyEquivalent: "")
        how.target = self; how.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
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
    @objc func setMetric(_ sender: NSMenuItem) { store.metric = Metric.allCases[sender.tag] }
    /// EcoLogits' methodology, behind every cloud estimate.
    @objc func openMethodology() { NSWorkspace.shared.open(URL(string: "https://ecologits.ai/latest/methodology/")!) }
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        try? s.status == .enabled ? s.unregister() : s.register()
    }
    @objc func toggleCompact() { store.compact.toggle() }
    @objc func openBrowserSetup() {
        store.compact = false
        store.showSetup = true
        panel.orderFront(nil)
        UserDefaults.standard.set(true, forKey: "showCompanion")
    }
    @objc func toggleCompanion() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFront(nil)
        UserDefaults.standard.set(panel.isVisible, forKey: "showCompanion")
    }

    /// Tracky's sprite (drop, spark or fire) as a template image for the menu bar.
    private func trackyIcon(_ m: Metric) -> NSImage {
        let rows = Sprites.awake(m), px: CGFloat = 1.4
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
if args.contains("--selftest") { selfTest(catalog: catalog); browserSelfTest(catalog: catalog); tipsSelfTest(); localSelfTest(); metricSelfTest(); exit(0) }
if args.contains("--dump") {   // what Tracky sees in the last 24 h
    for (name, us) in Dictionary(grouping: Store().load(), by: { $0.model.name }) {
        let i = us.reduce(Impact()) { $0 + $1.impact }
        print(name, us.count, "requests", us.reduce(0) { $0 + $1.output }, "output tokens |",
              Metric.allCases.map { m in "\(m.name) \(m.fmt(m.of(i).min))–\(m.fmt(m.of(i).max))" }.joined(separator: " | "))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--shots"), i + 1 < args.count {   // render the README screenshots into a folder
    let dir = URL(fileURLWithPath: args[i + 1]), store = Store()
    // Real usage plus a few sample browser events from half an hour ago, so the legend shows every kind of source.
    let samples = [#"{"site":"claude.ai","model":"claude-sonnet-5-5","tokens":4000}"#, #"{"site":"chatgpt.com","model":"gpt-5-2","tokens":3000}"#]
        + Array(repeating: #"{"site":"google-ai-overview"}"#, count: 40)
    store.usages = store.load() + samples.compactMap { BrowserEvent(json: Data($0.utf8))?.usage(at: Date().addingTimeInterval(-1800), catalog: catalog) }

    func card(_ m: Metric, _ heat: Int, asleep: Bool = false, compact: Bool = false) -> Companion {
        Companion(store: store, forced: (asleep, heat), forcedCompact: compact, forcedMetric: m)
    }
    func shot(_ name: String, dark: Bool = false, @ViewBuilder _ content: () -> some View) {
        let view = HStack(alignment: .top, spacing: 20) { content() }
            .padding(24).background(dark ? Color(white: 0.08) : Color(white: 0.9)).environment(\.colorScheme, dark ? .dark : .light)
        let png = MainActor.assumeIsolated { () -> Data? in   // top-level code runs on the main thread
            let r = ImageRenderer(content: view)
            r.scale = 2
            return r.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        try? png?.write(to: dir.appendingPathComponent(name + ".png"))
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // One picture of the three modes: the full card (water), the roast (energy) and the minimal card (CO₂).
    let roaster = Store()
    roaster.usages = store.usages
    roaster.roasting = true
    store.browserOn = true; roaster.browserOn = true   // green globes: browser tracking on
    shot("modes") {
        card(.water, 2)
        Companion(store: roaster, forced: (false, 3), forcedCompact: false, forcedMetric: .energy)
        card(.co2, 4, compact: true)
    }

    // The README's top: Tracky's drop as an icon, and a made-up desktop with the card and the open menu.
    func sprite(_ rows: [String], px: CGFloat, ink: Color? = nil) -> some View {
        let p = Palette(scheme: .light)
        return Canvas { ctx, _ in draw(rows, in: ctx, at: .zero, px: px, ink: ink ?? p.body, p) }
            .frame(width: 12 * px, height: CGFloat(rows.count) * px)
    }
    func save(_ name: String, _ view: some View) {
        let png = MainActor.assumeIsolated { () -> Data? in
            let r = ImageRenderer(content: view)
            r.scale = 2
            return r.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        try? png?.write(to: dir.appendingPathComponent(name + ".png"))
    }
    save("icon", sprite(Sprites.awake(.water), px: 8))

    let m = Metric.water, font = Font.system(size: 13)
    func menuRow(_ left: String, _ right: String = "", bold: Bool = false, check: Bool = false, sub: Bool = false, dim: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(check ? "✓" : "").frame(width: 18, alignment: .leading)
            Text(left).fontWeight(bold ? .semibold : .regular).foregroundStyle(dim ? .secondary : .primary)
            Spacer(minLength: 24)
            Text(sub ? "›" : right).fontWeight(bold ? .semibold : .regular).monospacedDigit()
        }.font(font).padding(.horizontal, 10).frame(height: 22)
    }
    func divider() -> some View { Divider().padding(.horizontal, 10).padding(.vertical, 4) }
    let menu = VStack(alignment: .leading, spacing: 0) {
        menuRow("\(m.name) · last \(Int(store.hours))h", "≈ " + m.fmt(m.of(store.impact).mid), bold: true)
        menuRow(others(m, store.impact), dim: true)
        divider()
        ForEach(Array(slices(store, m).enumerated()), id: \.offset) { menuRow($1.label, m.fmt($1.amount)) }
        divider()
        menuRow("💡 " + tips(store, m)[0])
        divider()
        menuRow("🌐  Browser tracking: on")
        divider()
        menuRow("Track", sub: true); menuRow("Period", sub: true)
        menuRow("Show on desktop", check: true); menuRow("Minimal card"); menuRow("Open at login", check: true)
        menuRow("How is this estimated?"); menuRow("Quit Tracky", "⌘Q")
    }
    .padding(.vertical, 5).frame(width: 330)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.97, opacity: 0.94)))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)

    let menuBar = HStack(spacing: 18) {
        Image(systemName: "apple.logo").font(.system(size: 15))
        Text("Finder").fontWeight(.bold)
        ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
        Spacer()
        HStack(spacing: 5) {
            sprite(Sprites.awake(m).map { String($0.map { "#%b".contains($0) ? "#" : " " }) }, px: 1.4, ink: .black)
            Text("≈ " + m.fmt(m.of(store.impact).mid)).monospacedDigit()
        }
        .padding(.horizontal, 7).frame(height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.1)))
        Image(systemName: "wifi"); Image(systemName: "battery.75percent")
        Text("Fri 31 Oct  10:41")
    }
    .font(.system(size: 13)).padding(.horizontal, 16).frame(height: 30).background(Color.white.opacity(0.55))

    let desktop = ZStack(alignment: .topLeading) {
        LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 0.93), Color(red: 0.55, green: 0.78, blue: 0.86),
                                Color(red: 0.95, green: 0.78, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
        Circle().fill(Color.white.opacity(0.18)).frame(width: 520).blur(radius: 60).offset(x: -120, y: 260)
        Circle().fill(Color(red: 0.2, green: 0.4, blue: 0.85).opacity(0.25)).frame(width: 600).blur(radius: 80).offset(x: 760, y: 220)
        card(.water, 2).shadow(color: .black.opacity(0.25), radius: 20, y: 10).offset(x: 110, y: 110)
        menu.offset(x: 1200 - 330 - 150, y: 34)
        menuBar
    }
    .frame(width: 1200, height: 540).clipped().environment(\.colorScheme, .light)
    save("desktop", desktop)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
