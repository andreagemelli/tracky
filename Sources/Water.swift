import Foundation

// Energy, CO₂ and water per LLM request, ported from EcoLogits 0.11.3 (MPL-2.0):
// ecologits/impacts/llm.py for energy, ecologits/tracers/utils.py for data centers.
// https://ecologits.ai/latest/methodology/llm_inference/

/// A min–max range, as EcoLogits reports every impact.
struct Amount {
    var min = 0.0, max = 0.0
    var mid: Double { (min + max) / 2 }
    static func + (a: Amount, b: Amount) -> Amount { Amount(min: a.min + b.min, max: a.max + b.max) }
    static func exactly(_ v: Double) -> Amount { Amount(min: v, max: v) }
}

/// What one request cost: energy in kWh, CO₂ in kg (CO₂-equivalent, usage plus embodied hardware), water in liters.
struct Impact {
    var energy = Amount(), co2 = Amount(), water = Amount()
    static func + (a: Impact, b: Impact) -> Impact { Impact(energy: a.energy + b.energy, co2: a.co2 + b.co2, water: a.water + b.water) }
    /// Electricity used where nothing else is known about it: CO₂ and water follow from the grid.
    static func fromEnergy(kWh: Double, kgCO2PerKWh: Double, litersPerKWh: Double) -> Impact {
        Impact(energy: .exactly(kWh), co2: .exactly(kWh * kgCO2PerKWh), water: .exactly(kWh * litersPerKWh))
    }
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
    // Embodied (manufacturing) CO₂ in kg, spread over a 3-year hardware life: EcoLogits adds it to usage CO₂.
    static let gpuEmbodiedKg = 273.0, serverEmbodiedKg = 5700.0, lifespanSeconds = 3.0 * 365 * 24 * 3600

    // tracers/utils.py PROVIDER_CONFIG_MAP: data-center PUE and on-site WUE (L/kWh), plus the grid of the
    // data-center country from electricity_mixes.json: CO₂ (kg/kWh) and off-site WUE (L/kWh).
    // USA 0.3844 and 3.1321, SWE 0.03526 and 6.0315, world average (WOR) 0.45829 and 3.908.
    static let providers: [String: (pue: ClosedRange<Double>, wue: ClosedRange<Double>, gwp: Double, offsite: Double)] = [
        "anthropic": (1.09...1.14, 0.13...0.999, 0.3844, 3.1321),
        "openai": (1.2...1.2, 0.569...0.569, 0.3844, 3.1321),
        "mistralai": (1.16...1.16, 0.09...0.09, 0.03526, 6.0315),
        "google_genai": (1.09...1.09, 0.999...0.999, 0.3844, 3.1321),
        "cohere": (1.09...1.09, 0.999...0.999, 0.3844, 3.1321),
        "huggingface_hub": (1.09...1.14, 0.13...0.99, 0.3844, 3.1321),
        // Not in EcoLogits: an unknown provider gets the widest PUE and WUE range above, on the world-average grid.
        "other": (1.09...1.2, 0.09...0.999, 0.45829, 3.908),
    ]

    static func impact(_ m: Model, outputTokens: Int) -> Impact {
        guard let p = providers[m.provider], outputTokens > 0 else { return Impact() }
        /// IT energy of the request (kWh): GPUs plus the server's share while generating, and its
        /// embodied CO₂ (kg): the hardware's manufacturing, by the share of its life this request used.
        func it(total: Double, active: Double) -> (kWh: Double, embodied: Double) {
            let n = Double(outputTokens)
            let gpuKWh = n * (gpuAlpha * exp(gpuBeta * batch) * active + gpuGamma) / 1000
            let perToken = m.tps.map { 1 / $0 } ?? (latAlpha * active + latBeta * batch + latGamma)
            // ponytail: EcoLogits caps latency at the measured request time; Tracky never measures it (EcoLogits' default, ∞).
            let latency = n * perToken + (m.ttft ?? 0)
            let gpus = pow(2, ceil(log2(ceil(1.2 * total * quantBits / 8 / gpuMemoryGB))))
            let serverKWh = latency / 3600 * serverPowerKW * gpus / serverGPUs / batch
            let hardwareKg = gpus / serverGPUs * serverEmbodiedKg + gpus * gpuEmbodiedKg
            return (serverKWh + gpus * gpuKWh, latency * hardwareKg / (lifespanSeconds * batch))
        }
        let lo = it(total: m.total.lowerBound, active: m.active.lowerBound), hi = it(total: m.total.upperBound, active: m.active.upperBound)
        let eLo = lo.kWh * p.pue.lowerBound, eHi = hi.kWh * p.pue.upperBound   // request energy = PUE × IT energy
        return Impact(energy: Amount(min: eLo, max: eHi),
                      co2: Amount(min: eLo * p.gwp + lo.embodied, max: eHi * p.gwp + hi.embodied),   // usage + embodied
                      water: Amount(min: lo.kWh * (p.wue.lowerBound + p.pue.lowerBound * p.offsite),
                                    max: hi.kWh * (p.wue.upperBound + p.pue.upperBound * p.offsite)))
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
    let impact: Impact
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
                     effort: d["perTurnEffort"] as? String, impact: EcoLogits.impact(model, outputTokens: output))
    }
}

/// `Tracky --selftest`: the port must match EcoLogits 0.11.3 for 1,000 output tokens.
func selfTest(catalog: Catalog) {
    // From EcoLogits 0.11.3: llm_impacts(...).energy, .gwp (usage + embodied) and .wcf for 1,000 output tokens.
    let expected: [(String, (Double, Double), (Double, Double), (Double, Double))] = [
        ("claude-opus-5-5", (0.003085698801768991, 0.005927633036420847), (0.0012507656738747085, 0.0023432051936748822),
         (0.010032736340167416, 0.02376041785739516)),
        ("claude-haiku-5-5", (5.6452841961726475e-05, 0.0001505414352996398), (2.3092516898075187e-05, 6.06522166251566e-05),
         (0.00018354885406522662, 0.0006034326662251073)),
        ("mistral-medium-3.5", (0.0005596380397157117, 0.0005596380397157117), (2.6930224758094356e-05, 2.6930224758094356e-05),
         (0.0034188770292818793, 0.0034188770292818793)),
        ("gemini-2.5-flash", (0.0013224741170826063, 0.002196364997851913), (0.0005493448322367242, 0.0008852684868044457),
         (0.005354186909605737, 0.008892233555509646)),
    ]
    func near(_ a: Amount, _ want: (Double, Double)) -> Bool { abs(a.min - want.0) / want.0 < 1e-9 && abs(a.max - want.1) / want.1 < 1e-9 }
    for (name, energy, co2, water) in expected {
        guard let m = catalog[name] else { fatalError("\(name) missing from models.json") }
        let i = EcoLogits.impact(m, outputTokens: 1000)
        precondition(near(i.energy, energy) && near(i.co2, co2) && near(i.water, water), "\(name): got \(i)")
    }
    print("selftest ok")
}
