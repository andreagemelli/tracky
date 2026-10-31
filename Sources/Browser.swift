import AppKit

// Browser support. The Tracky extension (extension/) reports each finished AI reply through Chrome
// native messaging. Chrome starts this binary as the host; it validates the event and appends one
// line to browser.jsonl, which the app reads like any other log.

let browserLog = NSString(string: "~/Library/Application Support/Tracky/browser.jsonl").expandingTildeInPath

/// Chrome's side of the link: the native messaging manifest that lets the extension reach Tracky,
/// and the check-in file the host touches whenever the extension talks to it.
enum ChromeLink {
    static let extensionID = "dcbfgnpofnkeooopckmnjbcdepjgphhh"   // pinned by the key in extension/manifest.json
    static let manifest = NSString(string: "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.tracky.json").expandingTildeInPath
    static let checkIn = NSString(string: "~/Library/Application Support/Tracky/browser-ping").expandingTildeInPath
    static let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")

    static var connected: Bool { FileManager.default.fileExists(atPath: manifest) }
    /// The extension checks in each time Chrome starts it; a day of silence means it is gone or Chrome is unused.
    static var extensionSeen: Bool {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: checkIn))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(d) < 24 * 3600
    }
    static var on: Bool { connected && extensionSeen }

    static func connect() {
        guard let bin = Bundle.main.executablePath else { return }
        let json: [String: Any] = ["name": "local.tracky", "description": "Tracky: counts the water behind AI replies",
                                   "path": bin, "type": "stdio", "allowed_origins": ["chrome-extension://\(extensionID)/"]]
        try? FileManager.default.createDirectory(atPath: (manifest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: URL(fileURLWithPath: manifest))
    }
    static func disconnect() { try? FileManager.default.removeItem(atPath: manifest) }

    /// Opens Chrome's extensions page and shows the bundled extension folder to load from.
    static func showExtension() {
        if let folder = Bundle.main.url(forResource: "extension", withExtension: nil) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        if let chrome, let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Google's measurement for a median Gemini Apps text prompt (Elsworth et al. 2025, "Measuring the
/// environmental impact of delivering AI at Google scale"): 0.24 Wh, 0.03 g CO₂e and 0.26 mL of water.
/// Used for every Gemini reply and AI Overview instead of an EcoLogits estimate.
let googlePerPrompt = Impact(energy: .exactly(0.00024), co2: .exactly(0.00003), water: .exactly(0.00026))

struct BrowserEvent: Equatable {
    static let sites: Set = ["claude.ai", "chatgpt.com", "gemini.google.com", "google-ai-overview"]
    let site: String
    let model: String?
    let tokens: Int

    /// Accepts a known site or a plain host name (any other AI chat site, measured by meter.js), a plain
    /// model id and a sane token count. Anything else is dropped.
    init?(json: Data) {
        guard let d = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let site = d["site"] as? String,
              Self.sites.contains(site) || site.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              site.count <= 64 else { return nil }
        self.site = site
        model = (d["model"] as? String).flatMap { $0.range(of: #"^[a-z0-9.\-]{1,64}$"#, options: .regularExpression) != nil ? $0 : nil }
        tokens = min(max(d["tokens"] as? Int ?? 0, 0), 100_000)
    }

    /// The model behind the event and its water.
    func usage(at date: Date, catalog: Catalog) -> Usage? {
        // Model ids as EcoLogits names them: ChatGPT's "gpt-5-2-thinking" is "gpt-5.2".
        let candidates: [String] = model.map { (m: String) -> [String] in
            let dotted = m.replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1.$2", options: .regularExpression)
            return [m, dotted, dotted.replacingOccurrences(of: #"-(thinking|instant|pro)$"#, with: "", options: .regularExpression)]
        } ?? []
        func estimate(_ m: Model, _ source: String) -> Usage {
            Usage(date: date, source: source, model: m, output: tokens, thinking: 0, effort: nil, impact: EcoLogits.impact(m, outputTokens: tokens))
        }
        switch site {
        case "claude.ai", "chatgpt.com":   // unknown models fall back to the site's usual default
            let fallback = site == "claude.ai" ? "claude-sonnet-5-5" : "gpt-5"
            guard let m = (candidates + [fallback]).lazy.compactMap({ catalog[$0] }).first else { return nil }
            return estimate(m, site == "claude.ai" ? "claude.ai" : "ChatGPT")
        case "gemini.google.com", "google-ai-overview":
            let m = Model(name: site == "gemini.google.com" ? "Gemini" : "Google AI Overview", provider: "google")
            return Usage(date: date, source: site == "gemini.google.com" ? "Gemini" : "Search", model: m, output: tokens,
                         thinking: 0, effort: nil, impact: googlePerPrompt)
        default:   // any other AI chat site: EcoLogits if it knows the model, else a wide stand-in
            let source = site.replacingOccurrences(of: #"^(chat|www)\."#, with: "", options: .regularExpression)
            if let m = candidates.lazy.compactMap({ catalog[$0] }).first {
                return estimate(m, source)
            }
            // ponytail: one size range for every unknown model; per-site sizes if a site is used a lot.
            return estimate(Model(name: model ?? "AI chat", provider: "other"), source)
        }
    }
}

/// Native messaging host: one length-prefixed JSON message in, one reply out (Chrome's protocol).
func runNativeHost() -> Never {
    func reply(_ ok: Bool) {
        let body = Data(#"{"ok":\#(ok)}"#.utf8)
        var len = UInt32(body.count)
        FileHandle.standardOutput.write(Data(bytes: &len, count: 4) + body)
    }
    let input = FileHandle.standardInput
    guard let head = try? input.read(upToCount: 4), head.count == 4 else { exit(0) }
    let len = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })   // native byte order, per the protocol
    guard len < 64_000, let body = try? input.read(upToCount: len), body.count == len else { reply(false); exit(0) }

    // Any message from the extension is a check-in; {"ping": true} is only that.
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (browserLog as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if !fm.createFile(atPath: ChromeLink.checkIn, contents: nil) { reply(false); exit(0) }
    if (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["ping"] as? Bool == true { reply(true); exit(0) }
    guard let e = BrowserEvent(json: body) else { reply(false); exit(0) }

    var line: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "site": e.site, "tokens": e.tokens]
    line["model"] = e.model
    if !fm.fileExists(atPath: browserLog) { fm.createFile(atPath: browserLog, contents: nil) }
    guard let data = try? JSONSerialization.data(withJSONObject: line), let h = FileHandle(forWritingAtPath: browserLog)
    else { reply(false); exit(0) }
    h.seekToEndOfFile()
    h.write(data + Data([0x0A]))
    try? h.close()
    reply(true)
    exit(0)
}

/// Reads browser.jsonl incrementally.
final class BrowserReader {
    private var offsets: [String: UInt64] = [:]
    private let iso = ISO8601DateFormatter()

    func read(since cutoff: Date, catalog: Catalog) -> [Usage] {
        newLines(browserLog, offsets: &offsets).compactMap { line in
            guard let e = BrowserEvent(json: line),
                  let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let date = (d["ts"] as? String).flatMap(iso.date(from:)), date > cutoff else { return nil }
            return e.usage(at: date, catalog: catalog)
        }
    }
}

func browserSelfTest(catalog: Catalog) {
    func event(_ s: String) -> BrowserEvent? { BrowserEvent(json: Data(s.utf8)) }
    precondition(event(#"{"site":"<script>","tokens":5}"#) == nil && event(#"{"site":"localhost","tokens":5}"#) == nil,
                 "anything but a host name must be dropped")
    precondition(event(#"{"site":"claude.ai","model":"x\"; rm","tokens":9999999}"#).map { $0.model == nil && $0.tokens == 100_000 } == true,
                 "bad model and huge token count must be cleaned")
    let opus = event(#"{"site":"claude.ai","model":"claude-opus-5-5","tokens":1000}"#)!.usage(at: Date(), catalog: catalog)!
    precondition(opus.impact.water.min == EcoLogits.impact(catalog["claude-opus-5-5"]!, outputTokens: 1000).water.min, "claude.ai must use EcoLogits")
    let gpt = event(#"{"site":"chatgpt.com","model":"gpt-5-2-thinking","tokens":1000}"#)!.usage(at: Date(), catalog: catalog)!
    precondition(gpt.model.name == "gpt-5.2", "ChatGPT slug must map to EcoLogits, got \(gpt.model.name)")
    precondition(event(#"{"site":"google-ai-overview"}"#)!.usage(at: Date(), catalog: catalog)!.impact.water.min == 0.00026)
    let mistral = event(#"{"site":"chat.mistral.ai","model":"mistral-medium-3.5","tokens":1000}"#)!.usage(at: Date(), catalog: catalog)!
    precondition(mistral.model.provider == "mistralai" && mistral.impact.water.min > 0 && mistral.source == "mistral.ai", "known models on other sites use EcoLogits")
    let qwen = event(#"{"site":"chat.qwen.ai","model":"qwen3.7-plus","tokens":1000}"#)!.usage(at: Date(), catalog: catalog)!
    precondition(qwen.model.provider == "other" && qwen.impact.water.min > 0 && qwen.impact.water.max > qwen.impact.water.min, "unknown models get a range")
    print("browser selftest ok")
}
