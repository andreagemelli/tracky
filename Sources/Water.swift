import Foundation

// Water estimate per LLM request, ported from EcoLogits 0.11.3 (MPL-2.0):
// ecologits/impacts/llm.py for energy, ecologits/tracers/utils.py for data centers.
// https://ecologits.ai/latest/methodology/llm_inference/

/// Liters of water, as the min–max range EcoLogits reports.
struct Liters {
    var min = 0.0, max = 0.0
    var mid: Double { (min + max) / 2 }
    static func + (a: Liters, b: Liters) -> Liters { Liters(min: a.min + b.min, max: a.max + b.max) }
}

struct Model {
    let name, provider: String
    let total, active: ClosedRange<Double>   // billions of parameters
    let tps, ttft: Double?                    // tokens/s and time to first token (OpenRouter)
}

enum EcoLogits {
    // llm.py
    static let gpuAlpha = 1.1665273170451914e-06, gpuBeta = -0.011205921025579175, gpuGamma = 4.052928146734005e-05
    static let latAlpha = 0.0006785088094353663, latBeta = 0.0003119310311688259, latGamma = 0.019473717579473387
    static let batch = 64.0, gpuMemoryGB = 80.0, serverGPUs = 8.0, serverPowerKW = 1.2, quantBits = 16.0

    // tracers/utils.py PROVIDER_CONFIG_MAP: data-center PUE and on-site WUE (L/kWh), plus the off-site
    // WUE (L/kWh) of the data-center country from electricity_mixes.json (USA 3.1321).
    static let providers: [String: (pue: ClosedRange<Double>, wue: ClosedRange<Double>, offsite: Double)] = [
        "anthropic": (1.09...1.14, 0.13...0.999, 3.1321),
        "openai": (1.2...1.2, 0.569...0.569, 3.1321),
        "mistralai": (1.16...1.16, 0.09...0.09, 6.0315),   // SWE
        // Not in EcoLogits: an unknown provider gets the widest PUE and WUE range above, with the
        // world-average off-site WUE (WOR 3.908).
        "other": (1.09...1.2, 0.09...0.999, 3.908),
    ]

    static func water(_ m: Model, outputTokens: Int) -> Liters {
        guard let p = providers[m.provider], outputTokens > 0 else { return Liters() }
        func one(total: Double, active: Double, pue: Double, wue: Double) -> Double {
            let n = Double(outputTokens)
            let gpuKWh = n * (gpuAlpha * exp(gpuBeta * batch) * active + gpuGamma) / 1000
            let perToken = m.tps.map { 1 / $0 } ?? (latAlpha * active + latBeta * batch + latGamma)
            let latency = n * perToken + (m.ttft ?? 0)
            let gpus = pow(2, ceil(log2(ceil(1.2 * total * quantBits / 8 / gpuMemoryGB))))
            let serverKWh = latency / 3600 * serverPowerKW * gpus / serverGPUs / batch
            return (serverKWh + gpus * gpuKWh) * (wue + pue * p.offsite)
        }
        return Liters(min: one(total: m.total.lowerBound, active: m.active.lowerBound, pue: p.pue.lowerBound, wue: p.wue.lowerBound),
                      max: one(total: m.total.upperBound, active: m.active.upperBound, pue: p.pue.upperBound, wue: p.wue.upperBound))
    }
}

/// EcoLogits' models.json: parameter estimates for open and proprietary models.
struct Catalog {
    private var models: [String: Model] = [:]
    private var aliases: [String: String] = [:]

    init(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func range(_ v: Any?) -> ClosedRange<Double>? {
            if let n = v as? Double { return n...n }
            if let r = v as? [String: Any], let lo = r["min"] as? Double, let hi = r["max"] as? Double { return lo...hi }
            return nil
        }
        for m in root["models"] as? [[String: Any]] ?? [] {
            guard let name = m["name"] as? String, let provider = m["provider"] as? String,
                  let arch = m["architecture"] as? [String: Any] else { continue }
            let params = arch["parameters"]
            let total, active: ClosedRange<Double>?
            if arch["type"] as? String == "moe", let p = params as? [String: Any] {
                (total, active) = (range(p["total"]), range(p["active"]))
            } else {
                (total, active) = (range(params), range(params))
            }
            guard let total, let active else { continue }
            let dep = m["deployment"] as? [String: Any]
            models[name] = Model(name: name, provider: provider, total: total, active: active,
                                 tps: dep?["tps"] as? Double, ttft: dep?["ttft"] as? Double)
        }
        for a in root["aliases"] as? [[String: Any]] ?? [] {
            if let name = a["name"] as? String, let target = a["alias"] as? String { aliases[name] = target }
        }
    }

    subscript(name: String) -> Model? {
        if let m = models[name] ?? aliases[name].flatMap({ models[$0] }) { return m }
        // "claude-x-20260101" → "claude-x"
        let undated = name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return undated == name ? nil : self[undated]
    }
}

/// One model request seen in a local log. Holds no prompt or reply text.
struct Usage {
    let date: Date
    let source: String   // where it ran: "Code", "claude.ai", "ChatGPT", "Gemini", "Search"
    let model: Model
    let output, thinking: Int
    let effort: String?
    let water: Liters
}

/// Complete lines appended to `path` since the last call; a half-written last line waits for next time.
func newLines(_ path: String, offsets: inout [String: UInt64]) -> [Data] {
    guard let h = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? h.close() }
    let start = offsets[path] ?? 0
    try? h.seek(toOffset: start)
    guard let data = try? h.readToEnd(), let nl = data.lastIndex(of: 0x0A) else { return [] }
    offsets[path] = start + UInt64(nl - data.startIndex + 1)
    return data[...nl].split(separator: 0x0A).map { Data($0) }
}

/// Reads Claude Code transcripts (~/.claude/projects/*/*.jsonl, written by the CLI and the
/// desktop app's Code tab). Incremental: remembers how far into each file it has read.
final class ClaudeCodeReader {
    private let dir = NSString(string: "~/.claude/projects").expandingTildeInPath
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()   // a reply can be logged on several lines with the same message id
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func read(since cutoff: Date, catalog: Catalog) -> [Usage] {
        let fm = FileManager.default
        var out: [Usage] = []
        for project in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let pdir = (dir as NSString).appendingPathComponent(project)
            for file in (try? fm.contentsOfDirectory(atPath: pdir)) ?? [] where file.hasSuffix(".jsonl") {
                let path = (pdir as NSString).appendingPathComponent(file)
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, mtime > cutoff
                else { continue }
                for line in newLines(path, offsets: &offsets) {
                    if let u = parse(line, cutoff: cutoff, catalog: catalog) { out.append(u) }
                }
            }
        }
        return out
    }

    private func parse(_ line: Data, cutoff: Date, catalog: Catalog) -> Usage? {
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              d["type"] as? String == "assistant",
              let msg = d["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any],
              let id = msg["id"] as? String, !seen.contains(id),
              let ts = d["timestamp"] as? String, let date = iso.date(from: ts), date > cutoff,
              let name = msg["model"] as? String, let model = catalog[name],
              let output = usage["output_tokens"] as? Int
        else { return nil }
        seen.insert(id)
        let thinking = (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int ?? 0
        return Usage(date: date, source: "Code", model: model, output: output, thinking: thinking,
                     effort: d["perTurnEffort"] as? String, water: EcoLogits.water(model, outputTokens: output))
    }
}

/// `Tracky --selftest`: the port must match EcoLogits 0.11.3 for 1,000 output tokens.
func selfTest(catalog: Catalog) {
    let expected: [(String, Double, Double)] = [   // from `llm_impacts(...).wcf`
        ("claude-opus-5-5", 0.010032736340167416, 0.02376041785739516),
        ("claude-haiku-5-5", 0.00018354885406522662, 0.0006034326662251073),
    ]
    for (name, lo, hi) in expected {
        guard let m = catalog[name] else { fatalError("\(name) missing from models.json") }
        let w = EcoLogits.water(m, outputTokens: 1000)
        precondition(abs(w.min - lo) / lo < 1e-9 && abs(w.max - hi) / hi < 1e-9, "\(name): got \(w), want \(lo)–\(hi)")
    }
    print("selftest ok")
}
