import Foundation

// Browser support. The Tracky extension (extension/) reports each finished AI reply through Chrome
// native messaging. Chrome starts this binary as the host; it validates the event and appends one
// line to browser.jsonl, which the app reads like any other log.

let browserLog = NSString(string: "~/Library/Application Support/Tracky/browser.jsonl").expandingTildeInPath

/// Google's measured water for a median Gemini Apps text prompt (Elsworth et al. 2025,
/// "Measuring the environmental impact of delivering AI at Google scale"), used for every
/// Gemini reply and AI Overview instead of an EcoLogits estimate.
let googleLitersPerPrompt = 0.00026

struct BrowserEvent: Equatable {
    static let sites: Set = ["claude.ai", "chatgpt.com", "gemini.google.com", "google-ai-overview"]
    let site: String
    let model: String?
    let tokens: Int

    /// Accepts only known sites, a plain model id and a sane token count. Anything else is dropped.
    init?(json: Data) {
        guard let d = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let site = d["site"] as? String, Self.sites.contains(site) else { return nil }
        self.site = site
        model = (d["model"] as? String).flatMap { $0.range(of: #"^[a-z0-9.\-]{1,64}$"#, options: .regularExpression) != nil ? $0 : nil }
        tokens = min(max(d["tokens"] as? Int ?? 0, 0), 100_000)
    }

    /// The model behind the event and its water. Unknown models fall back to the site's usual default.
    func usage(at date: Date, catalog: Catalog) -> Usage? {
        switch site {
        case "claude.ai", "chatgpt.com":
            let fallback = site == "claude.ai" ? "claude-sonnet-5-5" : "gpt-5"
            // ChatGPT slugs look like "gpt-5-2-thinking"; EcoLogits names them "gpt-5.2".
            let candidates: [String] = model.map { (m: String) -> [String] in
                let dotted = m.replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1.$2", options: .regularExpression)
                return [m, dotted, dotted.replacingOccurrences(of: #"-(thinking|instant|pro)$"#, with: "", options: .regularExpression)]
            } ?? []
            guard let m = (candidates + [fallback]).lazy.compactMap({ catalog[$0] }).first else { return nil }
            return Usage(date: date, model: m, output: tokens, thinking: 0, effort: nil, water: EcoLogits.water(m, outputTokens: tokens))
        default:
            let name = site == "gemini.google.com" ? "Gemini" : "Google AI Overview"
            let m = Model(name: name, provider: "google", total: 0...0, active: 0...0, tps: nil, ttft: nil)
            return Usage(date: date, model: m, output: tokens, thinking: 0, effort: nil,
                         water: Liters(min: googleLitersPerPrompt, max: googleLitersPerPrompt))
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
    guard len < 64_000, let body = try? input.read(upToCount: len), body.count == len, let e = BrowserEvent(json: body)
    else { reply(false); exit(0) }

    var line: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "site": e.site, "tokens": e.tokens]
    line["model"] = e.model
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (browserLog as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
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
    precondition(event(#"{"site":"evil.com","tokens":5}"#) == nil, "unknown site must be dropped")
    precondition(event(#"{"site":"claude.ai","model":"x\"; rm","tokens":9999999}"#).map { $0.model == nil && $0.tokens == 100_000 } == true,
                 "bad model and huge token count must be cleaned")
    let opus = event(#"{"site":"claude.ai","model":"claude-opus-5-5","tokens":1000}"#)!.usage(at: Date(), catalog: catalog)!
    precondition(abs(opus.water.min - 0.010032736340167416) < 1e-12, "claude.ai must use EcoLogits")
    let gpt = event(#"{"site":"chatgpt.com","model":"gpt-5-2-thinking","tokens":1000}"#)!.usage(at: Date(), catalog: catalog)!
    precondition(gpt.model.name == "gpt-5.2", "ChatGPT slug must map to EcoLogits, got \(gpt.model.name)")
    precondition(event(#"{"site":"google-ai-overview"}"#)!.usage(at: Date(), catalog: catalog)!.water.min == googleLitersPerPrompt)
    print("browser selftest ok")
}
