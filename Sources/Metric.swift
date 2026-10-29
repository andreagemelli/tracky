import Foundation

/// What Tracky is about. The user picks one; it sets Tracky's look, the meter, the ladder of everyday
/// amounts and the roast. The other two are reported on the side.
enum Metric: String, CaseIterable {
    case water, energy, co2

    var name: String { ["Water", "Energy", "CO₂"][index] }
    var noun: String { ["water", "energy", "CO₂"][index] }   // "~42× less water"
    var symbol: String { ["drop.fill", "bolt.fill", "smoke.fill"][index] }
    private var index: Int { Metric.allCases.firstIndex(of: self)! }

    func of(_ i: Impact) -> Amount { [i.water, i.energy, i.co2][index] }

    /// Liters, kWh or kg, written in the unit that reads best.
    func fmt(_ v: Double) -> String {
        let (big, small) = [("L", "mL"), ("kWh", "Wh"), ("kg", "g")][index], s = v * 1000
        return v >= 1 ? String(format: "%.2f %@", v, big) : s >= 10 ? String(format: "%.0f %@", s, small)
            : s >= 1 ? String(format: "%.1f %@", s, small) : s >= 0.005 ? String(format: "%.2f %@", s, small)
            : s > 0 ? "<0.01 \(small)" : "0 \(small)"
    }

    // Tracky's look: the top rows of its sprite (the face and body below are shared) and its colors.
    var top: [String] {
        [["     ##     ", "    ####    ", "   ######   "],   // a drop
         ["      ###   ", "     ###    ", "   #######  "],   // a spark with a bolt on its head
         ["   #   #    ", "  ##  ###   ", "  ### ####  "]][index]   // a little fire
    }
    var tint: (Double, Double, Double) { [(0.33, 0.62, 0.96), (0.99, 0.78, 0.2), (0.98, 0.52, 0.2)][index] }
    var shadeTint: (Double, Double, Double) { [(0.2, 0.45, 0.82), (0.92, 0.55, 0.1), (0.82, 0.25, 0.15)][index] }

    /// Everyday amounts, smallest first; passing one makes Tracky a level hotter.
    var ladder: [Rung] {
        switch self {
        case .water: [
            Rung(name: "a cup", amount: 0.25, sprite: Sprites.cup),
            Rung(name: "a bottle", amount: 1.5, sprite: Sprites.bottle),
            Rung(name: "a toilet flush", amount: 6, sprite: Sprites.toilet),   // US federal limit, 1.6 gal per flush (EPA WaterSense)
            Rung(name: "a bucket", amount: 10, sprite: Sprites.bucket),
            Rung(name: "a shower", amount: 60, sprite: Sprites.shower),        // average US shower, 15.8 gal (home-water-works.org)
            Rung(name: "a bathtub", amount: 150, sprite: Sprites.tub),
        ]
        case .energy: [
            Rung(name: "a phone charge", amount: 0.015, symbol: "iphone"),            // ~14 Wh battery plus charging losses
            Rung(name: "a laptop charge", amount: 0.0724, symbol: "laptopcomputer"),  // MacBook Pro 14" battery, 72.4 Wh (Apple)
            Rung(name: "a kettle", amount: 0.11, symbol: "cup.and.saucer.fill"),      // 1 L from 20 °C: 4.186 kJ/kg·K × 80 K = 0.093 kWh, ~85% efficient
            Rung(name: "a hot shower", amount: 1.74, symbol: "shower.fill"),          // 60 L warmed by 25 °C: 60 × 4.186 × 25 kJ
            Rung(name: "a home's day", amount: 7.4, symbol: "house.fill"),            // 2,700 kWh/year, ARERA's typical Italian household
            Rung(name: "a home's week", amount: 51.8, symbol: "calendar"),
        ]
        case .co2: [100.0, 1_000, 5_000, 20_000, 100_000, 500_000].map { m in    // average car, unknown fuel: 0.16691 kg CO₂e/km (UK DESNZ 2024)
            Rung(name: m < 1_000 ? "\(Int(m)) m by car" : "\(Int(m / 1_000)) km by car", amount: m / 1_000 * 0.16691, symbol: "car.fill")
        }
        }
    }

    /// What the same amount could have been, for the roast. CO₂ equivalents run on the Mac's region grid.
    var roast: [RoastItem] {
        let g = localGrid.kgCO2PerKWh
        return switch self {
        case .water: [   // the shower uses 2.1 gal/min (home-water-works.org); the tomato 214 L/kg (Hoekstra & Chapagain 2007), ~100 g each
            RoastItem(emoji: "☕️", amount: 0.03, one: "espresso", many: "espressos"),
            RoastItem(emoji: "🫖", amount: 0.25, one: "cup of tea", many: "cups of tea"),
            RoastItem(emoji: "🚿", amount: 7.95 / 60, one: "second of shower", many: "seconds of shower"),
            RoastItem(emoji: "🚽", amount: 6, one: "toilet flush", many: "toilet flushes"),
            RoastItem(emoji: "🍅", amount: 21.4, one: "tomato, grown", many: "tomatoes, grown"),
        ]
        case .energy: [
            RoastItem(emoji: "📱", amount: 0.015, one: "phone charge", many: "phone charges"),
            RoastItem(emoji: "💻", amount: 0.0724, one: "laptop charge", many: "laptop charges"),
            RoastItem(emoji: "💡", amount: 0.01, one: "hour of a 10 W bulb", many: "hours of a 10 W bulb"),
            RoastItem(emoji: "🫖", amount: 0.11, one: "kettle boiled", many: "kettles boiled"),
            RoastItem(emoji: "💨", amount: 2.0 / 60, one: "minute of a 2 kW hair dryer", many: "minutes of a 2 kW hair dryer"),
        ]
        case .co2: [
            RoastItem(emoji: "🚗", amount: 0.16691 / 1_000, one: "meter by car", many: "meters by car"),
            RoastItem(emoji: "📱", amount: 0.015 * g, one: "phone charge", many: "phone charges"),
            RoastItem(emoji: "💡", amount: 0.01 * g, one: "hour of a 10 W bulb", many: "hours of a 10 W bulb"),
            RoastItem(emoji: "🫖", amount: 0.11 * g, one: "kettle boiled", many: "kettles boiled"),
            RoastItem(emoji: "💨", amount: 2.0 / 60 * g, one: "minute of a 2 kW hair dryer", many: "minutes of a 2 kW hair dryer"),
        ]
        }
    }

    var shouts: [String] {
        [["Seriously?!", "I'm boiling!", "All that for this?!"],
         ["Seriously?!", "I'm fried!", "Bzzt! All that?!"],
         ["Seriously?!", "I'm smoking!", "All that for this?!"]][index]
    }
}

/// One step of a metric's ladder: drawn as a pixel sprite (water) or an SF Symbol.
struct Rung {
    let name: String, amount: Double
    var sprite: [String]? = nil, symbol: String? = nil
}

struct RoastItem {
    let emoji: String, amount: Double, one: String, many: String
}

/// The first rung not yet reached, how full it is, and its index (Tracky's heat level).
func rung(for v: Double, _ m: Metric) -> (rung: Rung, fill: Double, level: Int) {
    let l = m.ladder, i = l.firstIndex { v < $0.amount } ?? l.count - 1
    return (l[i], min(v / l[i].amount, 1), i)
}

func roastLine(_ item: RoastItem, _ total: Double) -> String {
    let n = total / item.amount
    return n >= 10 ? "\(Int(n)) \(item.many)" : n >= 1.05 ? String(format: "%.1f %@", n, item.many)
        : n >= 0.95 ? "1 \(item.one)" : "\(max(Int(n * 100), 1))% of a \(item.one)"
}

func metricSelfTest() {
    precondition(Metric.energy.fmt(0.0123) == "12 Wh" && Metric.co2.fmt(0.0046) == "4.6 g" && Metric.water.fmt(4.41) == "4.41 L")
    precondition(Metric.water.fmt(0.000017) == "0.02 mL" && Metric.water.fmt(0.0000001) == "<0.01 mL")
    precondition(rung(for: 0.5, .co2).rung.name == "5 km by car" && rung(for: 0.01, .energy).rung.name == "a phone charge")
    precondition(roastLine(Metric.water.roast[1], 4.41) == "17 cups of tea" && roastLine(Metric.water.roast[3], 6) == "1 toilet flush")
    precondition(roastLine(Metric.water.roast[3], 9) == "1.5 toilet flushes" && roastLine(Metric.water.roast[4], 4.41) == "20% of a tomato, grown")
    precondition(Metric.allCases.allSatisfy { $0.ladder.count == 6 && $0.top.count == 3 && $0.roast.count == 5 })
    print("metric selftest ok")
}
