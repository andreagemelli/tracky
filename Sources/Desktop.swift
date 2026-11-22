import Foundation

// Claude desktop app chats. The app is claude.ai in Electron and keeps each open conversation in
// IndexedDB: a LevelDB folder of V8-serialized values, the larger ones Snappy-compressed and some moved
// to blob files. The format is the app's own and undocumented, so everything here fails quietly.
// Only finished assistant replies are taken: when, which model, and how long (no token counts are
// stored, so length is turned into tokens like the browser extension does). No text is kept.

private let desktopRoot = NSString(string: "~/Library/Application Support/Claude/IndexedDB").expandingTildeInPath
private let desktopDB = desktopRoot + "/https_claude.ai_0.indexeddb.leveldb"
private let desktopBlobs = desktopRoot + "/https_claude.ai_0.indexeddb.blob"

private func varint(_ b: [UInt8], _ i: inout Int) -> Int? {
    var r = 0, s = 0
    while i < b.count, s < 63 {
        let c = b[i]; i += 1
        r |= Int(c & 0x7f) << s; s += 7
        if c < 0x80 { return r }
    }
    return nil
}

private func le(_ b: [UInt8], _ i: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | Int(b[i + $1]) << (8 * $1) } }

/// Snappy (raw format), as Chromium compresses LevelDB blocks and large IndexedDB values.
func unsnappy(_ b: [UInt8]) -> [UInt8]? {
    var i = 0
    guard let n = varint(b, &i), n < 256 << 20 else { return nil }
    var o: [UInt8] = []
    o.reserveCapacity(n)
    while i < b.count {
        let t = Int(b[i]); i += 1
        let len: Int, off: Int
        switch t & 3 {
        case 0:
            var l = t >> 2
            if l >= 60 { let nb = l - 59; guard i + nb <= b.count else { return nil }; l = le(b, i, nb); i += nb }
            guard i + l + 1 <= b.count else { return nil }
            o += b[i...(i + l)]; i += l + 1
            continue
        case 1: guard i < b.count else { return nil }; len = (t >> 2 & 7) + 4; off = (t >> 5) << 8 | Int(b[i]); i += 1
        case 2: guard i + 2 <= b.count else { return nil }; len = (t >> 2) + 1; off = le(b, i, 2); i += 2
        default: guard i + 4 <= b.count else { return nil }; len = (t >> 2) + 1; off = le(b, i, 4); i += 4
        }
        guard off > 0, off <= o.count else { return nil }
        for _ in 0..<len { o.append(o[o.count - off]) }
    }
    return o.count == n ? o : nil
}

/// LevelDB write-ahead log: 32 KB blocks of record fragments, joined back into write batches.
func logRecords(_ b: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = [], cur: [UInt8] = [], i = 0
    while i + 7 <= b.count {
        if 32768 - i % 32768 < 7 { i += 32768 - i % 32768; continue }   // block trailer
        let len = le(b, i + 4, 2), type = b[i + 6], s = i + 7
        guard s + len <= b.count else { break }   // still being written
        i = s + len
        switch type {
        case 1: out.append(Array(b[s..<i]))
        case 2: cur = Array(b[s..<i])
        case 3: cur += b[s..<i]
        case 4: out.append(cur + b[s..<i]); cur = []
        default: break
        }
    }
    return out
}

/// The values put by one write batch.
func batchValues(_ r: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = [], i = 12   // sequence number and count
    while i < r.count {
        let put = r[i] == 1; i += 1
        guard let kl = varint(r, &i), i + kl <= r.count else { break }
        i += kl
        if put {
            guard let vl = varint(r, &i), i + vl <= r.count else { break }
            out.append(Array(r[i..<(i + vl)])); i += vl
        }
    }
    return out
}

/// Every value in a LevelDB table (.ldb): footer → index block → data blocks.
func tableValues(_ b: [UInt8]) -> [[UInt8]] {
    func block(_ off: Int, _ size: Int) -> [UInt8]? {
        guard off >= 0, size >= 0, off + size + 5 <= b.count else { return nil }
        let d = Array(b[off..<(off + size)])
        return b[off + size] == 1 ? unsnappy(d) : d
    }
    func entries(_ blk: [UInt8]) -> [[UInt8]] {
        guard blk.count >= 4 else { return [] }
        let end = blk.count - 4 - 4 * le(blk, blk.count - 4, 4)
        var out: [[UInt8]] = [], i = 0
        while i < end {
            guard varint(blk, &i) != nil, let ns = varint(blk, &i), let vl = varint(blk, &i), i + ns + vl <= end else { break }
            i += ns
            out.append(Array(blk[i..<(i + vl)])); i += vl
        }
        return out
    }
    guard b.count >= 48 else { return [] }
    var i = b.count - 48
    guard varint(b, &i) != nil, varint(b, &i) != nil, let io = varint(b, &i), let isz = varint(b, &i),
          let index = block(io, isz) else { return [] }
    return entries(index).flatMap { h -> [[UInt8]] in
        var j = 0
        guard let o = varint(h, &j), let s = varint(h, &j), let blk = block(o, s) else { return [] }
        return entries(blk)
    }
}

/// A large IndexedDB value (and every blob file) is FF 11 02 followed by Snappy data.
func expand(_ v: [UInt8]) -> [UInt8] {
    let head = v.prefix(16)
    guard let p = head.indices.first(where: { $0 + 2 < v.count && v[$0] == 0xff && v[$0 + 1] == 0x11 && v[$0 + 2] == 0x02 }),
          let d = unsnappy(Array(v[(p + 3)...])) else { return v }
    return d
}

private func find(_ n: [UInt8], _ h: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
    let end = min(to ?? h.count, h.count)
    guard from >= 0, end - from >= n.count else { return nil }
    return h.withUnsafeBytes { hb in
        n.withUnsafeBytes { nb in
            memmem(hb.baseAddress! + from, end - from, nb.baseAddress!, n.count).map { UnsafeRawPointer($0) - hb.baseAddress! }
        }
    }
}

/// A V8 one-byte string token, the way keys and short values are serialized.
private func key(_ s: String) -> [UInt8] { [0x22, UInt8(s.utf8.count)] + Array(s.utf8) }

/// The V8-serialized string at `i` (Latin-1, UTF-16 or UTF-8), after any alignment padding.
private func v8String(_ d: [UInt8], _ at: Int) -> String? {
    var i = at
    while i < d.count, d[i] == 0 { i += 1 }
    guard i < d.count else { return nil }
    let tag = d[i]; i += 1
    guard let n = varint(d, &i), i + n <= d.count else { return nil }
    switch tag {
    case 0x22: return String(decoding: d[i..<(i + n)].map { UInt16($0) }, as: UTF16.self)
    case 0x63: return String(decoding: stride(from: i, to: i + n - 1, by: 2).map { UInt16(le(d, $0, 2)) }, as: UTF16.self)
    case 0x53: return String(decoding: d[i..<(i + n)], as: UTF8.self)
    default: return nil
    }
}

struct DesktopReply: Equatable {
    let id, model: String
    let effort: String?
    let date: Date
    let chars: Int     // visible reply text; thinking is not stored
    let done: Bool
}

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()

/// Assistant replies in every conversation snapshot (`kind: hub_transcript`) inside a value. A snapshot
/// lists its messages, then the conversation's current model and effort.
func desktopReplies(_ d: [UInt8]) -> [DesktopReply] {
    let marker = key("kind") + key("hub_transcript"), sender = key("sender"), assistant = key("assistant")
    let textBlock = key("type") + key("text") + key("text")
    var out: [DesktopReply] = []
    var at = find(marker, d)
    while let s = at {
        let end = find(marker, d, from: s + 1) ?? d.count
        at = end < d.count ? end : nil
        var senders: [Int] = [], j = s
        while let p = find(sender, d, from: j, to: end) { senders.append(p); j = p + 1 }
        guard let last = senders.last else { continue }
        // ponytail: one model per conversation (its current one); a mid-chat switch counts earlier replies as the new model.
        let model = find(key("model"), d, from: last, to: end).flatMap { v8String(d, $0 + 7) } ?? "claude-sonnet-5-5"
        let effort = find(key("effort_level"), d, from: last, to: end).flatMap { v8String(d, $0 + 14) }
        for (n, p) in senders.enumerated() where find(assistant, d, from: p + sender.count, to: p + sender.count + assistant.count) != nil {
            let stop = n + 1 < senders.count ? senders[n + 1] : end
            var u = max(s, p - 512), id: String?
            while let q = find(key("uuid"), d, from: u, to: p) { id = v8String(d, q + 6); u = q + 1 }
            guard let id, let ts = find(key("created_at"), d, from: p, to: stop).flatMap({ v8String(d, $0 + 12) }),
                  let date = iso.date(from: ts) else { continue }
            let done = find(key("stop_reason"), d, from: p, to: stop).map { $0 + 13 < d.count && d[$0 + 13] == 0x22 } ?? false
            var chars = 0, k = p
            while let q = find(textBlock, d, from: k, to: stop) {
                chars += v8String(d, q + textBlock.count)?.utf16.count ?? 0
                k = q + 1
            }
            out.append(DesktopReply(id: id, model: model, effort: effort, date: date, chars: chars, done: done))
        }
    }
    return out
}

/// Reads the Claude desktop app's chats. The .log is reread whenever it grows; tables and blob files
/// never change once written, so each is read once.
final class DesktopReader {
    private var sizes: [String: Int] = [:]
    private var seen = Set<String>()   // a reply shows up in many snapshots while it streams

    func read(since cutoff: Date, catalog: Catalog) -> [Usage] {
        let fm = FileManager.default
        let db = ((try? fm.contentsOfDirectory(atPath: desktopDB)) ?? []).filter { $0.hasSuffix(".log") || $0.hasSuffix(".ldb") }
            .map { desktopDB + "/" + $0 }
        let blobs = (fm.enumerator(atPath: desktopBlobs)?.allObjects as? [String] ?? []).map { desktopBlobs + "/" + $0 }
        var out: [Usage] = []
        for path in db + blobs {
            guard let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular,
                  let mtime = a[.modificationDate] as? Date, mtime > cutoff, let size = a[.size] as? Int, sizes[path] != size,
                  let data = fm.contents(atPath: path) else { continue }
            sizes[path] = size
            // ponytail: rereads the whole .log (a few MB at most) when it grows; track an offset if that ever shows up.
            let b = [UInt8](data)
            let values = path.hasSuffix(".log") ? logRecords(b).flatMap(batchValues) : path.hasSuffix(".ldb") ? tableValues(b) : [b]
            for v in values {
                for r in desktopReplies(expand(v)) where r.done && r.date > cutoff && !seen.contains(r.id) {
                    seen.insert(r.id)
                    guard let m = catalog[r.model] ?? catalog["claude-sonnet-5-5"] else { continue }
                    let tokens = r.chars / 4   // like the browser extension: ~4 characters per token
                    out.append(Usage(date: r.date, source: "Desktop", model: m, output: tokens, thinking: 0, effort: r.effort,
                                     impact: EcoLogits.impact(m, outputTokens: tokens)))
                }
            }
        }
        return out
    }
}

func desktopSelfTest() {
    // Snappy: literal "abc", then copy 6 bytes from 3 back.
    precondition(unsnappy([9, 0x08, 0x61, 0x62, 0x63, 0x09, 0x03]) == Array("abcabcabc".utf8), "snappy")

    func v8(_ parts: String...) -> [UInt8] { parts.flatMap(key) }
    func reply(_ id: String, _ text: String, done: Bool) -> [UInt8] {
        let head = v8("uuid", id, "sender", "assistant", "content", "type", "text", "text", text, "created_at", "2026-11-22T18:53:36.474Z")
        return head + (done ? v8("stop_reason", "end_turn") : v8("stop_reason") + [0x5f])   // 0x5f: undefined, still streaming
    }
    let human = v8("uuid", "h1", "sender", "human", "type", "text", "text", "not counted")
    let tail = v8("model", "claude-opus-5-5", "settings", "effort_level", "medium")
    let snapshot: [UInt8] = v8("kind", "hub_transcript") + human + reply("a1", "Doing well, thanks!", done: true)
        + human + reply("a2", "still stream", done: false) + tail
    let r = desktopReplies(snapshot)
    precondition(r.count == 2 && r[0].id == "a1" && r[0].chars == 19 && r[0].done && r[0].model == "claude-opus-5-5"
                 && r[0].effort == "medium" && !r[1].done, "desktop replies: \(r)")

    // The same snapshot, put by a write batch split over two log fragments.
    let batch = [UInt8](repeating: 0, count: 12) + [1, 1, 0x4b, UInt8(snapshot.count & 0x7f | 0x80), UInt8(snapshot.count >> 7)] + snapshot
    let half = batch.count / 2
    func frag(_ p: ArraySlice<UInt8>, _ type: UInt8) -> [UInt8] { [0, 0, 0, 0, UInt8(p.count & 0xff), UInt8(p.count >> 8), type] + p }
    let log = frag(batch[..<half], 2) + frag(batch[half...], 4)
    precondition(logRecords(log).flatMap(batchValues).flatMap(desktopReplies) == r, "log fragments must join back")
    print("desktop selftest ok")
}
