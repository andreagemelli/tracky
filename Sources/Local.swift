import Foundation

// Local models. Their water is not a data center's: it is the Mac's own electricity times the
// water used to generate it (no cooling towers at home). Energy is measured, not estimated:
// generation time from the model server times this Mac's extra power while generating.

/// Extra power this Mac draws while llama.cpp generates. Measured on a MacBook Pro M4 (Mac16,1) with
/// LFM2.5-350M: 23.2 W generating vs 4.0 W idle, averaged over a minute of battery telemetry (Oct 2026).
// ponytail: one figure for every model and Mac; bigger models draw more. Recalibrate per Mac if it matters.
let localWatts = 19.2

/// Off-site water of electricity, world average (EcoLogits electricity_mixes.json, "WOR").
let localLitersPerKWh = 3.908

let localLog = NSString(string: "~/Library/Application Support/Tracky/local.jsonl").expandingTildeInPath

/// Watches a llama.cpp server (llama-server --metrics) on its default address and logs each new
/// stretch of generation to local.jsonl: model, output tokens and seconds spent.
final class LlamaCpp {
    static let base = URL(string: "http://127.0.0.1:8080")!
    private var last: (tokens: Double, seconds: Double)?
    private var everDown = false   // a server that appears after Tracky started counts from zero

    func poll() {
        guard let text = get("metrics").flatMap({ String(data: $0, encoding: .utf8) }) else { everDown = true; last = nil; return }
        let m = Self.parse(text)
        guard let tokens = m["llamacpp:tokens_predicted_total"] else { return }
        let seconds = (m["llamacpp:tokens_predicted_seconds_total"] ?? 0) + (m["llamacpp:prompt_seconds_total"] ?? 0)
        defer { last = (tokens, seconds) }
        guard let prev = last ?? (everDown ? (0, 0) : nil) else { return }   // already running at launch: baseline only
        let restarted = tokens < prev.tokens
        let dTokens = restarted ? tokens : tokens - prev.tokens, dSeconds = restarted ? seconds : seconds - prev.seconds
        guard dTokens > 0 else { return }

        let model = get("props").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["model_path"] as? String }
            .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }   // "…-Q8_0.gguf" → "…"
            .map { $0.replacingOccurrences(of: #"[-.](I?Q\d\w*|[BF]?F(16|32))$"#, with: "", options: [.regularExpression, .caseInsensitive]) }
            ?? "llama.cpp model"
        appendLine(["ts": ISO8601DateFormatter().string(from: Date()), "source": "llama.cpp", "model": model,
                    "tokens": Int(dTokens), "seconds": dSeconds], to: localLog)
    }

    /// Prometheus text: "name value" per line, comments skipped.
    static func parse(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let v = Double(parts[1]) { out[String(parts[0])] = v }
        }
        return out
    }

    private func get(_ path: String) -> Data? {
        var req = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: 1)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, res, _ in
            if (res as? HTTPURLResponse)?.statusCode == 200 { out = data }
            done.signal()
        }.resume()
        done.wait()
        return out
    }
}

func appendLine(_ obj: [String: Any], to path: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
    guard let data = try? JSONSerialization.data(withJSONObject: obj), let h = FileHandle(forWritingAtPath: path) else { return }
    h.seekToEndOfFile()
    h.write(data + Data([0x0A]))
    try? h.close()
}

/// Water of one stretch of local generation.
func localUsage(model: String, tokens: Int, seconds: Double, date: Date, source: String) -> Usage {
    let liters = seconds * localWatts / 3_600_000 * localLitersPerKWh
    return Usage(date: date, source: source, model: Model(name: model, provider: "local", total: 0...0, active: 0...0, tps: nil, ttft: nil),
                 output: tokens, thinking: 0, effort: nil, water: Liters(min: liters, max: liters))
}

/// Reads local.jsonl incrementally.
final class LocalReader {
    private var offsets: [String: UInt64] = [:]
    private let iso = ISO8601DateFormatter()

    func read(since cutoff: Date) -> [Usage] {
        newLines(localLog, offsets: &offsets).compactMap { line in
            guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let date = (d["ts"] as? String).flatMap(iso.date(from:)), date > cutoff,
                  let model = d["model"] as? String, let tokens = d["tokens"] as? Int, let seconds = d["seconds"] as? Double
            else { return nil }
            return localUsage(model: model, tokens: tokens, seconds: seconds, date: date, source: d["source"] as? String ?? "local")
        }
    }
}

func localSelfTest() {
    let m = LlamaCpp.parse("# HELP x\nllamacpp:tokens_predicted_total 400\nllamacpp:tokens_predicted_seconds_total 2.02838\n")
    precondition(m["llamacpp:tokens_predicted_total"] == 400 && m["llamacpp:tokens_predicted_seconds_total"] == 2.02838)
    // The 400-token reply measured on the M4: ~2 s at 19.2 W → about 0.04 mL.
    let u = localUsage(model: "LFM2.5-350M", tokens: 400, seconds: 2.12, date: Date(), source: "llama.cpp")
    precondition(abs(u.water.min - 2.12 * 19.2 / 3_600_000 * 3.908) < 1e-15 && u.water.min * 1000 < 0.05)
    print("local selftest ok")
}
