import Foundation

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

/// A model as EcoLogits names it, or Tracky's own: "other" (unknown cloud model), "google", "local".
struct Model {
    let name, provider: String
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
