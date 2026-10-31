import Foundation
import JavaScriptCore

// Energy, CO₂ and water per LLM request, from EcoLogits' own estimator: ecologits.js (MPL-2.0), shipped
// unmodified in the app and run in macOS's JavaScriptCore. Tracky passes it a provider, a model and output
// tokens; the formulas, model sizes, data centers and electricity mixes are all theirs.
// https://ecologits.ai/latest/methodology/

enum EcoLogits {
    private static let js: JSContext = {
        let c = JSContext()!
        c.exceptionHandler = { _, e in FileHandle.standardError.write(Data("ecologits.js: \(e?.toString() ?? "?")\n".utf8)) }
        let lib = Bundle.main.url(forResource: "ecologits", withExtension: "js") ?? URL(fileURLWithPath: "build/package/dist/index.cjs")
        // Its CommonJS build in a function scope, with a silent console (it warns once per unreleased model architecture).
        c.evaluateScript("var console = {warn() {}, log() {}, info() {}, error() {}, debug() {}}, module = {exports: {}};"
            + "(function (module, exports) {\n" + ((try? String(contentsOf: lib, encoding: .utf8)) ?? "") + "\n})(module, module.exports);")
        c.evaluateScript("""
            var E = module.exports;
            function trackyAmounts(i) { return [i.energy, i.gwp, i.wcf].map(x => typeof x.value === "number" ? [x.value, x.value] : [x.value.min, x.value.max]); }
            // Tracky never measures request latency: EcoLogits' default, unbounded.
            function trackyImpact(provider, name, tokens) {
                const r = E.llmImpacts({provider, modelName: name, outputTokenCount: tokens, requestLatency: Infinity});
                return r.hasErrors ? null : trackyAmounts(r);
            }
            // Not in EcoLogits: an unknown model gets a wide size range and the widest provider PUE and WUE, on the world-average grid.
            function trackyStandIn(tokens) {
                const mix = E.electricityMixes.findElectricityMix("WOR");
                return trackyAmounts(E.computeLlmImpacts({
                    modelActiveParameterCount: new E.RangeValue(20, 100), modelTotalParameterCount: new E.RangeValue(200, 1000),
                    outputTokenCount: tokens, requestLatency: Infinity, datacenterPue: new E.RangeValue(1.09, 1.2), datacenterWue: new E.RangeValue(0.09, 0.999),
                    ifElectricityMixAdpe: mix.adpe, ifElectricityMixPe: mix.pe, ifElectricityMixGwp: mix.gwp, ifElectricityMixWue: mix.wue}));
            }
            function trackyModels() { return E.models.listModels().map(m => [m.name, m.provider]); }
            function trackyMix(zone) { const m = E.electricityMixes.findElectricityMix(zone); return m ? [m.gwp, m.wue] : null; }
            """)
        return c
    }()

    private static func call(_ f: String, _ args: [Any]) -> [Any]? { js.objectForKeyedSubscript(f).call(withArguments: args)?.toArray() }

    static var version: String { js.evaluateScript("E.ECOLOGITS_VERSION").toString() }

    /// EcoLogits' estimate; a stand-in range for provider "other"; nothing for providers it doesn't model.
    static func impact(_ m: Model, outputTokens: Int) -> Impact {
        guard outputTokens > 0,
              let r = (m.provider == "other" ? call("trackyStandIn", [outputTokens]) : call("trackyImpact", [m.provider, m.name, outputTokens])) as? [[Double]]
        else { return Impact() }
        let a = r.map { Amount(min: $0[0], max: $0[1]) }
        return Impact(energy: a[0], co2: a[1], water: a[2])
    }

    /// Every model EcoLogits knows, aliases included: (name, provider).
    static func models() -> [(String, String)] { (call("trackyModels", []) as? [[String]] ?? []).map { ($0[0], $0[1]) } }

    /// An electricity mix (ISO 3166-1 alpha-3 zone, "WOR" for the world): CO₂ in kg/kWh and water in L/kWh.
    static func mix(_ zone: String) -> (kgCO2PerKWh: Double, litersPerKWh: Double)? {
        (call("trackyMix", [zone]) as? [Double]).map { ($0[0], $0[1]) }
    }
}

/// Model lookup by name, as logs and sites write it.
struct Catalog {
    private var models: [String: Model] = [:]

    init() {
        for (name, provider) in EcoLogits.models() where models[name] == nil { models[name] = Model(name: name, provider: provider) }
    }

    subscript(name: String) -> Model? {
        if let m = models[name] { return m }
        // "claude-x-20260101" → "claude-x"
        let undated = name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return undated == name ? nil : self[undated]
    }
}

/// `Tracky --selftest`: ecologits.js loads and Tracky reads its answers right.
func selfTest(catalog: Catalog) {
    precondition(catalog["claude-opus-5-5"]?.provider == "anthropic" && catalog["gpt-5.2"]?.provider == "openai", "ecologits.js must load")
    let opus = EcoLogits.impact(catalog["claude-opus-5-5"]!, outputTokens: 1000), twice = EcoLogits.impact(catalog["claude-opus-5-5"]!, outputTokens: 2000)
    for (a, b) in [(opus.energy, twice.energy), (opus.co2, twice.co2), (opus.water, twice.water)] {
        precondition(a.min > 0 && a.min < a.max && b.min > a.min, "opus: got \(opus)")
    }
    // For scale (README): 1,000 Opus tokens are a few Wh, a gram or two of CO₂ and tens of mL of water.
    precondition((0.001...0.01).contains(opus.energy.mid) && (0.0005...0.005).contains(opus.co2.mid) && (0.005...0.05).contains(opus.water.mid), "opus: got \(opus)")
    let other = EcoLogits.impact(Model(name: "x", provider: "other"), outputTokens: 1000)
    precondition(other.water.min > 0 && other.water.max > other.water.min, "unknown models get a range")
    precondition(EcoLogits.impact(Model(name: "x", provider: "local"), outputTokens: 1000).energy.max == 0)
    precondition(EcoLogits.mix("WOR") != nil && EcoLogits.mix("XYZ") == nil)
    print("selftest ok (EcoLogits \(EcoLogits.version) via ecologits.js)")
}
